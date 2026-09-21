#!/bin/bash

## @file drain.sh
##
## The `submit drain` command: release prepared jobs to the scheduler in a loop,
## until the matching prepared queue is drained (or a cap / stop condition is
## hit). It is pure orchestration over `submit next` — it records no row and no
## provenance node of its own (knit_without_provenance); every release still
## flows through `submit next`, which advances the existing "jobs" row.
##
## Pacing is selected by --max-inflight: 1 (default) releases one job at a time
## and waits for each (serial); 0 releases every matching job without waiting
## (no limit); values greater than 1 keep several jobs alive at once (throttled).

# ------------------------------------------------------------------------------
# @fn _knit_drain_release_next()
#
# Release the next prepared job by re-executing the experiment as `submit next`
# (without --wait), then, when asked to wait, block on `job wait` for its outcome.
# This is the single, stubbable point through which draining releases a job, so
# the loop logic can be unit-tested against a simulated queue without a live
# scheduler.
#
# The released job's UUID is printed to stdout, and the exit status reflects its
# outcome when waiting: `submit next` prints the UUID and returns non-zero (empty
# stdout) once the queue is drained, so the caller distinguishes "drained" from
# "released" by an empty UUID; `job wait` then returns non-zero for a `failed` or
# `killed` job. `submit --wait` is deliberately not used — it returns 0 even for a
# job whose body failed, so it cannot detect failure (see features/submit-drain.md
# §4.2).
#
# @param[in] wait_flag "true" to wait for the released job's outcome (via
#                  `job wait`), else "false".
# @param[in] ... Filter arguments forwarded verbatim to `submit next` (for
#                  example --type / --group).
# ------------------------------------------------------------------------------
_knit_drain_release_next() {
    local wait_flag="$1"
    shift
    local uuid
    uuid="$("${_KNIT_SCRIPT_PATH}" submit next "$@")" || true
    [[ -z "${uuid}" ]] && return 1
    printf '%s\n' "${uuid}"
    [[ "${wait_flag}" != "true" ]] && return 0
    "${_KNIT_SCRIPT_PATH}" job wait --id "${uuid}" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_report()
#
# Print the end-of-run summary. The human-readable line always goes to stderr
# (via the logging system): with no jobs released it reports that the queue was
# empty; in "no-limit" mode it reports only the count (no per-job outcome was
# observed); otherwise it reports the completed / failed breakdown. When
# json_summary is "true" a machine-readable JSON object is additionally printed
# to stdout (see _knit_drain_emit_json). Always returns 0 so it does not disturb
# the caller's exit status.
#
# @param[in] mode         "no-limit" or "waiting".
# @param[in] json_summary "true" to also print the JSON object to stdout.
# @param[in] released     Number of jobs released this run.
# @param[in] completed    Number that completed successfully ("" in no-limit).
# @param[in] failed       Number that failed ("" in no-limit).
# @param[in] drained      "true" when the prepared queue was emptied.
# @param[in] stopped      "true" when a failure halted the drain early.
# ------------------------------------------------------------------------------
_knit_drain_report() {
    local mode="$1" json_summary="$2"
    local released="$3" completed="$4" failed="$5" drained="$6" stopped="$7"
    if (( released == 0 )); then
        knit_info "No prepared jobs to release."
    elif [[ "${mode}" == "no-limit" ]]; then
        knit_info "Released ${released} job(s)."
    else
        knit_info "Released ${released} job(s): ${completed} completed, ${failed} failed."
    fi
    if [[ "${json_summary}" == "true" ]]; then
        _knit_drain_emit_json "${mode}" "${released}" "${completed}" "${failed}" \
            "${drained}" "${stopped}"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_emit_json()
#
# Print the end-of-run summary as a single JSON object to stdout, built with
# _knit_jq so it is always well-formed and correctly typed: released is a number,
# completed / failed are numbers in waiting modes and null in no-limit mode,
# drained / stopped / dry_run are booleans. dry_run is always false here (the
# dry-run path emits its own summary).
#
# @param[in] mode      "no-limit" or "waiting".
# @param[in] released  Number of jobs released this run.
# @param[in] completed Number that completed successfully ("" in no-limit).
# @param[in] failed    Number that failed ("" in no-limit).
# @param[in] drained   "true" when the prepared queue was emptied.
# @param[in] stopped   "true" when a failure halted the drain early.
# ------------------------------------------------------------------------------
_knit_drain_emit_json() {
    local mode="$1" released="$2" completed="$3" failed="$4" drained="$5" stopped="$6"
    local completed_json="${completed}" failed_json="${failed}"
    if [[ "${mode}" == "no-limit" ]]; then
        completed_json="null"
        failed_json="null"
    fi
    # shellcheck disable=SC2016 # $released etc. are jq variables, not shell
    _knit_jq -nc \
        --argjson released "${released}" \
        --argjson completed "${completed_json}" \
        --argjson failed "${failed_json}" \
        --argjson drained "${drained}" \
        --argjson stopped "${stopped}" \
        --argjson dry_run "false" \
        '{released: $released, completed: $completed, failed: $failed, drained: $drained, stopped: $stopped, dry_run: $dry_run}'
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_nolimit()
#
# No-limit draining (--max-inflight 0): release every matching prepared job,
# back to back, without waiting. Stops when the queue is drained or --count is
# reached. No per-job outcome is observed, so this always succeeds on a clean
# drain.
#
# @param[in] count        Maximum jobs to release, or "" for no cap.
# @param[in] json_summary "true" to also print the JSON summary to stdout.
# @param[in] ...          Filter arguments forwarded to _knit_drain_release_next.
# ------------------------------------------------------------------------------
_knit_drain_nolimit() {
    local count="$1" json_summary="$2"
    shift 2
    local -a filters=("$@")
    local released=0 uuid drained="false"
    while [[ -z "${count}" ]] || (( released < count )); do
        uuid="$(_knit_drain_release_next false "${filters[@]}")" || true
        if [[ -z "${uuid}" ]]; then
            drained="true"
            break
        fi
        released=$(( released + 1 ))
    done
    _knit_drain_report "no-limit" "${json_summary}" "${released}" "" "" "${drained}" "false"
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_serial()
#
# Serial draining (--max-inflight 1): release one job, wait for it, release the
# next, until the queue is drained or --count is reached. Counts completed and
# failed jobs; with stop_on_failure it stops releasing new jobs after the first
# failure. Returns 0 when every released job succeeded, 1 otherwise.
#
# @param[in] stop_on_failure "true" to stop after the first failed job.
# @param[in] count           Maximum jobs to release, or "" for no cap.
# @param[in] json_summary    "true" to also print the JSON summary to stdout.
# @param[in] ...             Filter arguments forwarded to
#                        _knit_drain_release_next.
# ------------------------------------------------------------------------------
_knit_drain_serial() {
    local stop_on_failure="$1"
    local count="$2"
    local json_summary="$3"
    shift 3
    local -a filters=("$@")
    local released=0 completed=0 failed=0 uuid rc
    local drained="false" stopped="false"
    while [[ -z "${count}" ]] || (( released < count )); do
        uuid="$(_knit_drain_release_next true "${filters[@]}")" && rc=0 || rc=$?
        if [[ -z "${uuid}" ]]; then
            drained="true"
            break
        fi
        released=$(( released + 1 ))
        if (( rc == 0 )); then
            completed=$(( completed + 1 ))
        else
            failed=$(( failed + 1 ))
            if [[ "${stop_on_failure}" == "true" ]]; then
                stopped="true"
                break
            fi
        fi
    done
    _knit_drain_report "waiting" "${json_summary}" "${released}" "${completed}" \
        "${failed}" "${drained}" "${stopped}"
    (( failed == 0 ))
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_pool_worker()
#
# A single pool worker: release one job (waiting for it) and write its outcome as
# a "<uuid>\t<rc>" line to the given result file. Run in the background by
# _knit_drain_pool; the result file is how the pool reaps the worker and learns
# whether it claimed a job (non-empty uuid) and how it fared (rc). A worker
# always writes a result, so the pool never blocks on a worker that produced
# nothing.
#
# @param[in] result_file Path the worker writes its "<uuid>\t<rc>" line to.
# @param[in] ...         Filter arguments forwarded to _knit_drain_release_next.
# ------------------------------------------------------------------------------
_knit_drain_pool_worker() {
    local result_file="$1"
    shift
    local uuid rc
    uuid="$(_knit_drain_release_next true "$@")" && rc=0 || rc=$?
    printf '%s\t%s\n' "${uuid}" "${rc}" > "${result_file}"
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_pool()
#
# Throttled draining (--max-inflight N > 1): keep at most N jobs alive at once.
# The pool tops up to N background workers, then blocks on "wait -n" until any
# worker finishes and reaps every worker whose result file is ready. A worker
# that claimed no job marks the queue drained; a worker whose job failed bumps
# the failure count and, with stop_on_failure, stops further top-ups. The top-up
# guard "released + inflight < count" caps total claims at --count (each worker
# claims at most one job). All in-flight workers are drained before returning.
# Returns 0 when every released job succeeded, 1 otherwise.
#
# @param[in] max_inflight   Maximum concurrent workers (> 1).
# @param[in] stop_on_failure "true" to stop topping up after the first failure.
# @param[in] count          Maximum jobs to release, or "" for no cap.
# @param[in] json_summary   "true" to also print the JSON summary to stdout.
# @param[in] ...            Filter arguments forwarded to the workers.
# ------------------------------------------------------------------------------
_knit_drain_pool() {
    local max_inflight="$1"
    local stop_on_failure="$2"
    local count="$3"
    local json_summary="$4"
    shift 4
    local -a filters=("$@")

    local workdir
    workdir="$(mktemp -d)"

    local inflight=0 released=0 completed=0 failed=0 next_id=0
    local drained="false" stop="false"
    local -A worker_file=()

    while true; do
        # Top up to max_inflight, respecting --count and the drained/stop flags.
        while (( inflight < max_inflight )) \
            && [[ "${drained}" == "false" && "${stop}" == "false" ]] \
            && { [[ -z "${count}" ]] || (( released + inflight < count )); }; do
            local rf="${workdir}/w${next_id}"
            next_id=$(( next_id + 1 ))
            _knit_drain_pool_worker "${rf}" "${filters[@]}" &
            worker_file["$!"]="${rf}"
            inflight=$(( inflight + 1 ))
        done

        (( inflight == 0 )) && break

        # Block until at least one worker finishes, then reap every worker whose
        # result file is ready (a worker writes its file just before exiting).
        wait -n 2>/dev/null || true

        local pid rf line uuid rc
        for pid in "${!worker_file[@]}"; do
            rf="${worker_file[${pid}]}"
            [[ -s "${rf}" ]] || continue
            wait "${pid}" 2>/dev/null || true
            unset 'worker_file[${pid}]'
            inflight=$(( inflight - 1 ))
            line=""
            IFS= read -r line < "${rf}" || line=""
            rm -f "${rf}"
            uuid="${line%%$'\t'*}"
            rc="${line#*$'\t'}"
            if [[ -z "${uuid}" ]]; then
                drained="true"
            else
                released=$(( released + 1 ))
                if [[ "${rc}" == "0" ]]; then
                    completed=$(( completed + 1 ))
                else
                    failed=$(( failed + 1 ))
                    [[ "${stop_on_failure}" == "true" ]] && stop="true"
                fi
            fi
        done
    done

    rm -rf "${workdir}"
    _knit_drain_report "waiting" "${json_summary}" "${released}" "${completed}" \
        "${failed}" "${drained}" "${stop}"
    [[ "${failed}" == "0" ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_dry_run_json()
#
# Print the dry-run peek as a JSON object to stdout: {dry_run, count, jobs}, where
# jobs is the array sqlite emits in -json mode (id / job / group per row). An
# empty result set yields an empty array. Built with _knit_jq so the wrapper
# object is well-formed.
#
# @param[in] sql The read-only SELECT to run in sqlite -json mode.
# ------------------------------------------------------------------------------
_knit_drain_dry_run_json() {
    local sql="$1"
    local rows
    rows="$(_knit_sqlite3 -json "${sql}")"
    [[ -z "${rows}" ]] && rows="[]"
    # shellcheck disable=SC2016 # $jobs is a jq variable, not shell
    _knit_jq -nc --argjson jobs "${rows}" \
        '{dry_run: true, count: ($jobs | length), jobs: $jobs}'
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_dry_run()
#
# List the prepared jobs that would be released, in release order, without
# claiming or releasing anything. The peek mirrors _knit_prepare_claim_next: the
# same state='prepared' filter (plus optional job / group), the same
# ORDER BY id ASC, and --count applied as a LIMIT. It is a read-only SELECT (no
# write lock), so it never advances a job's state. Each matching job prints as
# "<uuid>  <job>" (with "  [<group>]" appended when the job has a group); with
# json_summary the peeked list is printed as JSON instead. A count of matches is
# reported to stderr.
#
# @param[in] count        Maximum jobs to list, or "" for no cap.
# @param[in] json_summary "true" to print the JSON list instead of the table.
# @param[in] job          Optional job-name filter (empty means any).
# @param[in] group        Optional group filter (empty means any).
# ------------------------------------------------------------------------------
_knit_drain_dry_run() {
    local count="$1" json_summary="$2" job="$3" group="$4"

    local -a conds=("state='prepared'")
    local esc
    if [[ -n "${job}" ]]; then
        _knit_sql_escape esc "${job}"
        conds+=("job='${esc}'")
    fi
    local group_ident
    _knit_db_sql_ident group_ident "group"
    if [[ -n "${group}" ]]; then
        _knit_sql_escape esc "${group}"
        conds+=("${group_ident}='${esc}'")
    fi
    local where
    printf -v where '%s AND ' "${conds[@]}"
    where="${where% AND }"

    local jobs_ident id_ident
    _knit_db_sql_ident jobs_ident "${_KNIT_JOBS_TABLE}"
    _knit_db_sql_ident id_ident "id"
    local limit=""
    [[ -n "${count}" ]] && limit=" LIMIT ${count}"
    local sql="SELECT ${id_ident}, job, ${group_ident} FROM ${jobs_ident} WHERE ${where} ORDER BY ${id_ident} ASC${limit};"

    if [[ "${json_summary}" == "true" ]]; then
        _knit_drain_dry_run_json "${sql}"
        return 0
    fi

    local id job_name grp listed=0
    while IFS=$'\x1f' read -r id job_name grp; do
        [[ -z "${id}" ]] && continue
        if [[ -n "${grp}" ]]; then
            printf '%s  %s  [%s]\n' "${id}" "${job_name}" "${grp}"
        else
            printf '%s  %s\n' "${id}" "${job_name}"
        fi
        listed=$(( listed + 1 ))
    done < <(_knit_sqlite3 -separator $'\x1f' "${sql}")
    knit_info "${listed} prepared job(s) would be released (dry run)."
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_detach_backend()
#
# Resolve the detach backend to use. "auto" prefers tmux, then screen, then
# nohup (nohup is part of coreutils, so it is the always-available fallback). A
# named backend (tmux / screen / nohup) that is not installed is a fatal error,
# and an unrecognized value is fatal too. Presence is probed through
# _knit_command_path so it can be stubbed in tests.
#
# @param[out] __knit_ret Name of the variable to receive the resolved backend.
# @param[in] requested  "auto", "tmux", "screen", or "nohup".
# ------------------------------------------------------------------------------
_knit_drain_detach_backend() {
    local -n __knit_ret=$1
    local requested="$2"
    case "${requested}" in
        tmux|screen|nohup)
            if [[ -z "$(_knit_command_path "${requested}")" ]]; then
                knit_fatal "submit drain: --detach-backend ${requested} was requested but ${requested} is not installed."
            fi
            __knit_ret="${requested}"
            ;;
        auto)
            if [[ -n "$(_knit_command_path tmux)" ]]; then
                __knit_ret="tmux"
            elif [[ -n "$(_knit_command_path screen)" ]]; then
                __knit_ret="screen"
            else
                __knit_ret="nohup"
            fi
            ;;
        *)
            knit_fatal "submit drain: unknown --detach-backend \"${requested}\" (expected auto, tmux, screen, or nohup)."
            ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_child_argv()
#
# Build the argv that the detached session runs: the experiment re-executed as
# `submit drain` with the same filters and pacing, but WITHOUT the detach options
# (so the child runs the loop in the foreground inside the session). The
# experiment path is _KNIT_SCRIPT_PATH (resolved at load).
#
# @param[out] __knit_ret     Name of the array variable to fill with the argv.
# @param[in] type            Job-type filter, or "".
# @param[in] group           Group filter, or "".
# @param[in] max_inflight    Concurrency level.
# @param[in] count           Release cap, or "".
# @param[in] stop_on_failure "true"/"false".
# @param[in] json_summary    "true"/"false".
# ------------------------------------------------------------------------------
_knit_drain_child_argv() {
    # shellcheck disable=SC2178 # nameref to the caller's indexed array
    local -n __knit_ret=$1
    local type="$2" group="$3" max_inflight="$4" count="$5"
    local stop_on_failure="$6" json_summary="$7"
    __knit_ret=("${_KNIT_SCRIPT_PATH}" submit drain)
    [[ -n "${type}" ]] && __knit_ret+=(--type "${type}")
    [[ -n "${group}" ]] && __knit_ret+=(--group "${group}")
    __knit_ret+=(--max-inflight "${max_inflight}")
    [[ -n "${count}" ]] && __knit_ret+=(--count "${count}")
    [[ "${stop_on_failure}" == "true" ]] && __knit_ret+=(--stop-on-failure)
    [[ "${json_summary}" == "true" ]] && __knit_ret+=(--json-summary)
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_launch_argv()
#
# Build the argv that actually starts the detached session for the given backend,
# given the (already %q-escaped) child command string. tmux and screen run the
# child through a shell and tee its output to the log, and close their session
# when the child exits. The nohup backend runs the child under setsid (or nohup
# when setsid is absent) with output redirected to the log; the caller
# backgrounds it.
#
# @param[out] __knit_ret Name of the array variable to fill with the argv.
# @param[in] backend   "tmux", "screen", or "nohup".
# @param[in] session   Session name (tmux/screen).
# @param[in] log       Path the output is written to.
# @param[in] child_str The %q-escaped child command string.
# ------------------------------------------------------------------------------
_knit_drain_launch_argv() {
    # shellcheck disable=SC2178 # nameref to the caller's indexed array
    local -n __knit_ret=$1
    local backend="$2" session="$3" log="$4" child_str="$5"
    local log_q
    printf -v log_q '%q' "${log}"
    case "${backend}" in
        tmux)
            __knit_ret=(tmux new-session -d -s "${session}" \
                "${child_str} 2>&1 | tee ${log_q}")
            ;;
        screen)
            __knit_ret=(screen -dmS "${session}" bash -lc \
                "${child_str} 2>&1 | tee ${log_q}")
            ;;
        nohup)
            local runner="nohup"
            [[ -n "$(_knit_command_path setsid)" ]] && runner="setsid"
            __knit_ret=("${runner}" bash -c \
                "${child_str} > ${log_q} 2>&1 < /dev/null")
            ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_spawn()
#
# Start the detached session. For the nohup backend the command is backgrounded,
# detached from this shell's stdio, and its PID is printed (for the "Stop"
# hint); for tmux / screen the command returns immediately on its own. Factored
# out so tests can stub the actual spawn.
#
# @param[in] backend "tmux", "screen", or "nohup".
# @param[in] ...     The launch argv to execute.
# ------------------------------------------------------------------------------
_knit_drain_spawn() {
    local backend="$1"
    shift
    if [[ "${backend}" == "nohup" ]]; then
        "$@" </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!"
        disown 2>/dev/null || true
    else
        "$@"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_detach_message()
#
# Print how to reattach to, follow, and stop the detached drain, to stderr. tmux
# and screen have a reattachable session; the nohup backend has only a PID.
#
# @param[in] backend "tmux", "screen", or "nohup".
# @param[in] session Session name (tmux/screen).
# @param[in] log     Path the output is written to.
# @param[in] pid     Background PID (nohup backend).
# ------------------------------------------------------------------------------
_knit_drain_detach_message() {
    local backend="$1" session="$2" log="$3" pid="$4"
    case "${backend}" in
        tmux)
            knit_info "Draining in the background (tmux session \"${session}\")."
            knit_info "  Reattach: tmux attach -t ${session}"
            knit_info "  Log:      tail -f ${log}"
            knit_info "  Stop:     tmux kill-session -t ${session}"
            ;;
        screen)
            knit_info "Draining in the background (screen session \"${session}\")."
            knit_info "  Reattach: screen -r ${session}"
            knit_info "  Log:      tail -f ${log}"
            knit_info "  Stop:     screen -S ${session} -X quit"
            ;;
        nohup)
            knit_info "Draining in the background (pid ${pid})."
            knit_info "  Log:  tail -f ${log}"
            knit_info "  Stop: kill ${pid}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_detach()
#
# Run the drain loop in a detached background session and return immediately.
# Resolves the backend, warns when the nohup backend cannot honor an explicit
# --session, ensures the log directory exists, rebuilds the child command (with
# the detach options stripped) and its backend launch argv, spawns it, and prints
# how to reattach / follow / stop it.
#
# @param[in] backend_req     Requested backend ("auto"/"tmux"/"screen"/"nohup").
# @param[in] session         Resolved session name.
# @param[in] session_explicit "true" when the user set --session.
# @param[in] log             Resolved log path.
# @param[in] type            Job-type filter, or "".
# @param[in] group           Group filter, or "".
# @param[in] max_inflight    Concurrency level.
# @param[in] count           Release cap, or "".
# @param[in] stop_on_failure "true"/"false".
# @param[in] json_summary    "true"/"false".
# ------------------------------------------------------------------------------
_knit_drain_detach() {
    local backend_req="$1" session="$2" session_explicit="$3" log="$4"
    local type="$5" group="$6" max_inflight="$7" count="$8"
    local stop_on_failure="$9" json_summary="${10}"

    local backend
    _knit_drain_detach_backend backend "${backend_req}"

    if [[ "${backend}" == "nohup" && "${session_explicit}" == "true" ]]; then
        knit_warning "submit drain: --session is ignored by the nohup backend (no reattachable session)."
    fi

    mkdir -p "$(dirname "${log}")"

    local -a child
    _knit_drain_child_argv child "${type}" "${group}" "${max_inflight}" \
        "${count}" "${stop_on_failure}" "${json_summary}"
    local child_str
    printf -v child_str '%q ' "${child[@]}"
    child_str="${child_str% }"

    local -a launch
    _knit_drain_launch_argv launch "${backend}" "${session}" "${log}" "${child_str}"

    local pid
    pid="$(_knit_drain_spawn "${backend}" "${launch[@]}")"

    _knit_drain_detach_message "${backend}" "${session}" "${log}" "${pid}"
}

# ------------------------------------------------------------------------------
# Release prepared jobs in a loop until the queue drains.
# ------------------------------------------------------------------------------
knit_register "submit:drain" _knit_submit_drain \
    "Release prepared jobs in a loop until the prepared queue drains."
_knit_is_builtin
# Like `submit next`, draining records no row and no provenance node of its own;
# each release advances an existing "jobs" row through `submit next`.
knit_without_provenance
knit_with_optional "type:string" "" "Only release jobs of this type (the job name)."
knit_with_optional "group:string" "" "Only release jobs in this group."
knit_with_optional "max-inflight:integer" "1" \
    "Maximum jobs kept alive in the scheduler at once (0 = no limit, no waiting; 1 = serial)."
knit_with_optional "count:integer" "" \
    "Release at most this many jobs this run (default: all matching)."
knit_with_flag "stop-on-failure" \
    "Stop releasing new jobs after the first failed job." \
    --when '.max_inflight > 0'
knit_with_flag "json-summary" \
    "Print a machine-readable JSON summary object to stdout at the end."
knit_with_flag "dry-run" \
    "List the prepared jobs that would be released, without releasing any."
knit_with_flag "detached" \
    "Run the drain loop in the background and return immediately."
knit_with_optional "detach-backend:string" "auto" \
    "Detach backend to use: auto (tmux, else screen, else nohup), tmux, screen, or nohup." \
    --when '.detached == "true"'
knit_with_optional "session:string" "" \
    "Name of the tmux/screen session to reattach to (default: knit-drain-<timestamp>)." \
    --when '.detached == "true"'
knit_with_optional "log:string" "" \
    "File the detached run's output is written to (default: .knit/drain/<session>.log)." \
    --when '.detached == "true"'
# ------------------------------------------------------------------------------
# @fn _knit_submit_drain()
#
# Entry point for the `submit drain` CLI command. Validates the pacing options
# and dispatches to the mode selected by --max-inflight: 0 drains without
# waiting (_knit_drain_nolimit), 1 drains serially (_knit_drain_serial), and a
# value greater than 1 drains through a bounded worker pool (_knit_drain_pool).
# With --dry-run it only lists what would be released (_knit_drain_dry_run) and
# claims nothing. The exit status reflects whether any released job failed
# (waiting modes).
#
# Usage:
# ```
# ./exp.sh submit drain [--type <t>] [--group <g>] [--max-inflight <n>] \
#     [--count <n>] [--stop-on-failure] [--json-summary] [--dry-run] \
#     [--detached [--detach-backend <b>] [--session <name>] [--log <path>]]
# ```
# ------------------------------------------------------------------------------
_knit_submit_drain() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local type group max_inflight count stop_on_failure json_summary dry_run
    local detached detach_backend session log
    type=$(knit_get_parameter "type" "$@") || type=""
    group=$(knit_get_parameter "group" "$@") || group=""
    max_inflight=$(knit_get_parameter "max-inflight" "$@") || max_inflight="1"
    count=$(knit_get_parameter "count" "$@") || count=""
    stop_on_failure=$(knit_get_parameter "stop-on-failure" "$@") || stop_on_failure="false"
    json_summary=$(knit_get_parameter "json-summary" "$@") || json_summary="false"
    dry_run=$(knit_get_parameter "dry-run" "$@") || dry_run="false"
    detached=$(knit_get_parameter "detached" "$@") || detached="false"
    detach_backend=$(knit_get_parameter "detach-backend" "$@") || detach_backend="auto"
    session=$(knit_get_parameter "session" "$@") || session=""
    log=$(knit_get_parameter "log" "$@") || log=""

    # The framework already enforced integer-ness; only the ranges remain.
    if (( max_inflight < 0 )); then
        knit_fatal "submit drain: --max-inflight must be 0 or greater (got \"${max_inflight}\")."
    fi
    if [[ -n "${count}" ]] && (( count < 1 )); then
        knit_fatal "submit drain: --count must be 1 or greater (got \"${count}\")."
    fi

    # A dry run only lists what would be released; it claims nothing and ignores
    # the pacing and detach options.
    if [[ "${dry_run}" == "true" ]]; then
        _knit_drain_dry_run "${count}" "${json_summary}" "${type}" "${group}"
        return 0
    fi

    # Detached: hand the same drain off to a background session and return.
    if [[ "${detached}" == "true" ]]; then
        local session_explicit="false"
        [[ -n "${session}" ]] && session_explicit="true"
        [[ -z "${session}" ]] && session="knit-drain-$(date +%Y%m%d-%H%M%S)"
        [[ -z "${log}" ]] && log="${_KNIT_PREFIX}/drain/${session}.log"
        _knit_drain_detach "${detach_backend}" "${session}" "${session_explicit}" \
            "${log}" "${type}" "${group}" "${max_inflight}" "${count}" \
            "${stop_on_failure}" "${json_summary}"
        return 0
    fi

    local -a filters=()
    [[ -n "${type}" ]] && filters+=(--type "${type}")
    [[ -n "${group}" ]] && filters+=(--group "${group}")

    if (( max_inflight == 0 )); then
        _knit_drain_nolimit "${count}" "${json_summary}" "${filters[@]}"
    elif (( max_inflight == 1 )); then
        _knit_drain_serial "${stop_on_failure}" "${count}" "${json_summary}" "${filters[@]}"
    else
        _knit_drain_pool "${max_inflight}" "${stop_on_failure}" "${count}" \
            "${json_summary}" "${filters[@]}"
    fi
}
knit_done
