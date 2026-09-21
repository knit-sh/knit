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
# Release the next prepared job by re-executing the experiment as `submit next`.
# This is the single, stubbable point through which draining releases a job, so
# the loop logic can be unit-tested against a simulated queue without a live
# scheduler.
#
# The released job's UUID is printed to stdout (empty when the prepared queue is
# drained), and the exit status is the released job's own status when waiting, or
# the release status otherwise. Callers distinguish "queue drained" from "job
# failed" by the presence of a UUID on stdout, never by the exit status alone.
#
# @param[in] wait_flag "true" to wait for the released job (adds --wait), else
#                  "false".
# @param[in] ... Filter arguments forwarded verbatim to `submit next` (for
#                  example --type / --group).
# ------------------------------------------------------------------------------
_knit_drain_release_next() {
    local wait_flag="$1"
    shift
    local -a cmd=("${_KNIT_SCRIPT_PATH}" submit next "$@")
    [[ "${wait_flag}" == "true" ]] && cmd+=(--wait)
    "${cmd[@]}"
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
# ------------------------------------------------------------------------------
# @fn _knit_submit_drain()
#
# Entry point for the `submit drain` CLI command. Validates the pacing options
# and dispatches to the mode selected by --max-inflight: 0 drains without
# waiting (_knit_drain_nolimit), 1 drains serially (_knit_drain_serial), and a
# value greater than 1 drains through a bounded worker pool (_knit_drain_pool).
# The exit status reflects whether any released job failed (waiting modes).
#
# Usage:
# ```
# ./exp.sh submit drain [--type <t>] [--group <g>] [--max-inflight <n>] \
#     [--count <n>] [--stop-on-failure] [--json-summary]
# ```
# ------------------------------------------------------------------------------
_knit_submit_drain() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local type group max_inflight count stop_on_failure json_summary
    type=$(knit_get_parameter "type" "$@") || type=""
    group=$(knit_get_parameter "group" "$@") || group=""
    max_inflight=$(knit_get_parameter "max-inflight" "$@") || max_inflight="1"
    count=$(knit_get_parameter "count" "$@") || count=""
    stop_on_failure=$(knit_get_parameter "stop-on-failure" "$@") || stop_on_failure="false"
    json_summary=$(knit_get_parameter "json-summary" "$@") || json_summary="false"

    # The framework already enforced integer-ness; only the ranges remain.
    if (( max_inflight < 0 )); then
        knit_fatal "submit drain: --max-inflight must be 0 or greater (got \"${max_inflight}\")."
    fi
    if [[ -n "${count}" ]] && (( count < 1 )); then
        knit_fatal "submit drain: --count must be 1 or greater (got \"${count}\")."
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
