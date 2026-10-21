#!/bin/bash

## @file job_cli.sh
##
## Commands for inspecting submitted jobs (`job list`, `job status`, `job wait`,
## `job show`, ...). Job *submission* lives in `job.sh`; this file holds the
## read-side commands that query the `jobs` table and a job's working directory.

# ------------------------------------------------------------------------------
# Registration of the job command group. Its subcommands (status / list / wait /
# cancel / resubmit / show, and show's own stdout / stderr / script) are
# registered lazily by _knit_job_discover the first time any of them is reached.
# ------------------------------------------------------------------------------
knit_register job knit_empty "Inspect submitted jobs."
_knit_is_builtin
knit_with_subcommand_discovery _knit_job_discover
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_job_status()
#
# Look up a job by its UUID in the jobs table and print its lifecycle state
# (e.g. submitted, running, completed, failed, killed). An unknown id is an error.
# ------------------------------------------------------------------------------
_knit_job_status() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local id
    id=$(knit_get_parameter "id" "$@")
    local state esc_id
    _knit_sql_escape esc_id "${id}"
    state=$(_knit_sqlite3 \
        "SELECT state FROM jobs WHERE id = '${esc_id}';")
    if [[ -z "${state}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    printf '%s\n' "${state}"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_in_clause()
#
# Build a SQL "<column> IN (...)" condition from a comma-separated list of
# values, each escaped as a single-quoted literal. Empty entries are dropped;
# nothing is printed when the list has no non-empty value, so the caller can test
# for an empty result and skip the condition entirely.
#
# @param[in] column Column name to match (interpolated verbatim, so a trusted name).
# @param[in] csv    Comma-separated list of values.
# ------------------------------------------------------------------------------
_knit_job_in_clause() {
    local column="$1" csv="$2"
    local -a in_values=()
    local part
    local -a parts
    IFS=',' read -ra parts <<< "${csv}"
    local esc_part
    for part in "${parts[@]}"; do
        [[ -z "${part}" ]] && continue
        _knit_sql_escape esc_part "${part}"
        in_values+=("'${esc_part}'")
    done
    [[ "${#in_values[@]}" -eq 0 ]] && return 0
    local in_list
    printf -v in_list '%s, ' "${in_values[@]}"
    printf '%s IN (%s)' "${column}" "${in_list%, }"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_list()
#
# Print a table of submitted jobs (id, job name, state), one row per job.
#
# --status adds an equality filter on the lifecycle state. The setup filter is
# the OR of two optional parts: --no-setup matches jobs with no setup (setup
# column NULL or empty), and --setup takes a comma-separated list of setup paths
# matched with SQL IN. Given both, a job qualifies if it has no setup OR its
# setup is in the list, e.g. "--no-setup --setup a,b,c". When neither is given
# no setup filter is applied. --types takes a comma-separated list of job types
# (the job name recorded in the "job" column) matched with SQL IN. All three
# filters (status, setup, types) are AND-ed together.
#
# By default the result is rendered with aligned columns and a header row. With
# --json the same filtered query is emitted as a JSON array (one object per job,
# or [] when nothing matches), using sqlite's -json output; the filters apply
# identically in both modes.
# ------------------------------------------------------------------------------
_knit_job_list() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local status setup types no_setup json
    status=$(knit_get_parameter "status" "$@")
    setup=$(knit_get_parameter "setup" "$@")
    types=$(knit_get_parameter "types" "$@")
    no_setup=$(knit_get_parameter "no-setup" "$@") || no_setup="false"
    json=$(knit_get_parameter "json" "$@") || json="false"

    local -a conditions=()
    if [[ -n "${status}" ]]; then
        local esc_status
        _knit_sql_escape esc_status "${status}"
        conditions+=("state = '${esc_status}'")
    fi

    # Build the setup filter as the OR of --no-setup and the --setup IN list.
    local -a setup_conditions=()
    [[ "${no_setup}" == "true" ]] \
        && setup_conditions+=("setup IS NULL OR setup = ''")
    if [[ -n "${setup}" ]]; then
        local setup_in
        setup_in="$(_knit_job_in_clause "setup" "${setup}")"
        [[ -n "${setup_in}" ]] && setup_conditions+=("${setup_in}")
    fi
    if [[ "${#setup_conditions[@]}" -gt 0 ]]; then
        local setup_group
        printf -v setup_group '%s OR ' "${setup_conditions[@]}"
        conditions+=("(${setup_group% OR })")
    fi

    # Filter by job type (the "job" column) when --types is given.
    if [[ -n "${types}" ]]; then
        local types_in
        types_in="$(_knit_job_in_clause "job" "${types}")"
        [[ -n "${types_in}" ]] && conditions+=("${types_in}")
    fi

    local statement="SELECT id, job, state FROM jobs"
    if [[ "${#conditions[@]}" -gt 0 ]]; then
        local where
        printf -v where ' AND %s' "${conditions[@]}"
        statement="${statement} WHERE ${where# AND }"
    fi
    statement="${statement} ORDER BY id;"

    if [[ "${json}" == "true" ]]; then
        local out
        out="$(_knit_sqlite3 -json "${statement}")"
        [[ -z "${out}" ]] && out="[]"
        printf '%s\n' "${out}"
        return 0
    fi

    _knit_sqlite3 -header -column "${statement}"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_dir()
#
# Print the working directory of a job given its UUID. Every job lives in one job
# root, <job-root>/<id>, regardless of which setup (if any) it used: the job root
# is resolved from bootstrap metadata (__job_path__) against the experiment root
# (see _knit_job_root).
#
# @param[in] id Job UUID.
# ------------------------------------------------------------------------------
_knit_job_dir() {
    local id="$1"
    local job_root
    _knit_job_root job_root
    printf '%s\n' "${job_root}/${id}"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_wait_one()
#
# Block until a single job finishes, then print its terminal lifecycle state; a
# "killed" or "failed" state yields a non-zero exit so callers can detect
# failure.
#
# Rather than busy-polling the database, this blocks on the scheduler itself:
# once the job's row is not already terminal, it looks up the backend job id
# (.job.id in the job directory) and calls the backend's native wait
# (_knit_sched_wait), which returns when the scheduler stops running the job. The
# job's terminal state (completed/failed/killed) is recorded by its compute-side
# callbacks over the shared filesystem; that write is read back afterwards, with
# a short reconciliation window since it may land a moment after the scheduler
# reports the job gone. An unknown id is a fatal error rather than an endless
# wait.
#
# @param[in] id  The job UUID to wait for.
# ------------------------------------------------------------------------------
_knit_job_wait_one() {
    local id="$1"
    local escaped
    _knit_sql_escape escaped "${id}"

    local state
    state="$(_knit_sqlite3 "SELECT state FROM jobs WHERE id = '${escaped}';")"
    if [[ -z "${state}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    # Already finished: no need to involve the scheduler.
    case "${state}" in
        completed)     printf '%s\n' "${state}"; return 0 ;;
        failed|killed) printf '%s\n' "${state}"; return 1 ;;
    esac

    # Block on the scheduler using the backend job id recorded at submit time.
    local jobdir jobid
    jobdir="$(_knit_job_dir "${id}")"
    if [[ ! -f "${jobdir}/.job.id" ]]; then
        knit_fatal "Job \"${id}\" has no recorded launcher id (${jobdir}/.job.id is missing)."
    fi
    local backend
    _knit_jobid_read backend jobid "${jobdir}"
    _knit_sched_wait "${backend}" "${jobid}"

    # The scheduler reports the job gone; give the compute-side terminal-state
    # write a brief window to become visible, then report it.
    local tries=0
    while true; do
        state="$(_knit_sqlite3 "SELECT state FROM jobs WHERE id = '${escaped}';")"
        case "${state}" in
            completed)     printf '%s\n' "${state}"; return 0 ;;
            failed|killed) printf '%s\n' "${state}"; return 1 ;;
        esac
        tries=$(( tries + 1 ))
        [[ "${tries}" -ge 5 ]] && break
        sleep "${_KNIT_SCHED_POLL_INTERVAL}"
    done

    # The scheduler finished the job but knit never recorded a terminal state
    # (e.g. status tracking was disabled or failed). Report what we have.
    knit_warning "Job \"${id}\" is no longer running but its recorded state is \"${state}\"."
    printf '%s\n' "${state}"
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_job_wait()
#
# Block until one or more jobs reach a terminal state, printing each job's
# terminal lifecycle state (one per line, in the order given).
#
# The --id argument accepts a comma-separated list of job UUIDs. Each job is
# waited for in turn via _knit_job_wait_one. The exit code aggregates the
# single-job convention: it is non-zero if ANY job ended "failed" or "killed",
# zero otherwise. A missing/unknown id anywhere in the list is a fatal error. A
# single id behaves exactly as waiting for that one job.
# ------------------------------------------------------------------------------
_knit_job_wait() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local id
    id=$(knit_get_parameter "id" "$@")

    local ids
    IFS=',' read -r -a ids <<< "${id}"

    local rc=0 one
    for one in "${ids[@]}"; do
        _knit_job_wait_one "${one}" || rc=1
    done
    return "${rc}"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_cancel()
#
# Cancel a job that is still running by asking its scheduler backend to terminate
# it, then recording the job's row as "killed". The backend job id is read from
# the job directory's .job.id (as `job wait` does) and handed to the backend's
# cancel primitive (local -> kill, slurm -> scancel, pbs -> qdel).
#
# A prepared job (state "prepared") was never dispatched, so there is no
# scheduler job to cancel: it is simply removed (row, job directory, and any
# --name alias), the same teardown as a rejected submission. That branch runs
# before the .job.id lookup, since a prepared job has no launcher id.
#
# Cancelling a job that has already reached a terminal state (completed or
# killed) is a no-op with an informational message. An unknown id is fatal, and
# a still-running job whose .job.id is missing errors rather than reporting a
# cancellation that did not happen.
#
# The compute side may also record "killed" via its pre-termination signal trap,
# but the row is updated here as well so it stays consistent for backends or
# races where that handler never runs (e.g. a hard kill, or a remote node whose
# write has not yet landed).
# ------------------------------------------------------------------------------
_knit_job_cancel() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local id
    id=$(knit_get_parameter "id" "$@")
    local escaped
    _knit_sql_escape escaped "${id}"

    local state
    state="$(_knit_sqlite3 "SELECT state FROM jobs WHERE id = '${escaped}';")"
    if [[ -z "${state}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    # A prepared job never reached the scheduler: there is no launcher id to look
    # up and nothing to cancel, so just remove its bookkeeping.
    if [[ "${state}" == "prepared" ]]; then
        _knit_prepare_remove "${id}"
        knit_info "Removed prepared job \"${id}\"."
        return 0
    fi
    # Already finished: there is nothing to cancel.
    case "${state}" in
        completed|failed|killed)
            knit_info "Job \"${id}\" is already ${state}; nothing to cancel."
            return 0
            ;;
    esac

    # Resolve the backend job id recorded at submit time.
    local jobdir jobid
    jobdir="$(_knit_job_dir "${id}")"
    if [[ ! -f "${jobdir}/.job.id" ]]; then
        knit_fatal "Job \"${id}\" has no recorded launcher id (${jobdir}/.job.id is missing)."
    fi
    local backend
    _knit_jobid_read backend jobid "${jobdir}"
    _knit_sched_cancel "${backend}" "${jobid}"
    _knit_db_update_row "${_KNIT_JOBS_TABLE}" "${id}" "state=killed"
    knit_info "Cancelled job \"${id}\"."
}

# ------------------------------------------------------------------------------
# @fn _knit_job_reset_validate_states()
#
# Check that a comma-separated --state list names only states that `job reset`
# may re-queue, and abort (knit_fatal) otherwise. The terminal-failed states
# "killed" and "failed" are always allowed; "completed" is allowed only when the
# caller passed --force (a deliberate redo). Any other state (including the
# non-terminal "running"/"submitting"/"prepared"/"submitted", which reset never
# touches) or an unknown value is rejected, as is an empty list.
#
# @param[in] csv   The comma-separated --state list.
# @param[in] force "true" when --force was given (allows "completed").
# ------------------------------------------------------------------------------
_knit_job_reset_validate_states() {
    local csv="$1" force="$2"
    local allowed="killed, failed"
    [[ "${force}" == "true" ]] && allowed="killed, failed, completed"
    local -a parts
    IFS=',' read -ra parts <<< "${csv}"
    local part saw=0
    for part in "${parts[@]}"; do
        part="${part//[[:space:]]/}"
        [[ -z "${part}" ]] && continue
        saw=1
        case "${part}" in
            killed|failed) ;;
            completed)
                [[ "${force}" == "true" ]] && continue
                knit_fatal "job reset: resetting a \"completed\" job needs --force."
                ;;
            *)
                knit_fatal "job reset: invalid --state value \"%s\" (allowed: %s)." \
                    "${part}" "${allowed}"
                ;;
        esac
    done
    (( saw )) || knit_fatal "job reset: --state must name at least one state."
}

# ------------------------------------------------------------------------------
# @fn _knit_job_reset_one()
#
# Re-queue a single job row for a retry: move it back to state "prepared" and
# clear the artifacts of its previous run, so the next `submit drain` claims and
# re-runs it from the same recorded inputs. The durable folder, the batch script,
# and the recorded arguments are preserved (prepare wrote them and they do not
# change); only the run-specific fields are cleared, restoring the row to the
# shape a freshly-prepared job has: "state" -> prepared, "hostnames" and
# "native-cmd" emptied, and the "retries" counter incremented. The stale backend
# launcher id (<jobdir>/.job.id) is removed so a re-dispatch records a fresh one.
# The job keeps its id and its provenance; no new row or edge is created.
#
# @param[in] id      The job UUID (its jobs-row id).
# @param[in] current The job's current "retries" count (NULL coalesced to 0 by
#                the caller), bumped by one here.
# ------------------------------------------------------------------------------
_knit_job_reset_one() {
    local id="$1" current="$2"
    local new=$(( current + 1 ))
    _knit_db_update_row "${_KNIT_JOBS_TABLE}" "${id}" \
        "state=prepared" "hostnames=" "native-cmd=" "retries=${new}"
    local jobdir
    jobdir="$(_knit_job_dir "${id}")"
    rm -f "${jobdir}/.job.id"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_reset_apply()
#
# Re-queue every job matching the selectors whose state is in states_csv back to
# "prepared" for a retry (see _knit_job_reset_one). This is the shared worker
# behind `job reset` and `submit drain --retry`, so the two surfaces cannot
# drift. The selectors are AND-ed: states_csv (a validated non-empty list of
# source states), plus an optional id / group / job-type equality. A job whose
# "retries" count already reached max_retries is left terminal and warned about,
# so a poison job cannot be retried without bound; an empty max_retries means no
# cap. Each re-queued id is printed to stdout (in id order); a one-line count
# goes to stderr. Resetting nothing is not an error (idempotent): a scope with no
# matching terminal job simply reports zero.
#
# @param[in] states_csv  Comma-separated source states to reset (already validated).
# @param[in] max_retries Retry cap, or "" for no cap.
# @param[in] sel_id      Optional job UUID to match (empty means any).
# @param[in] sel_group   Optional group to match (empty means any).
# @param[in] sel_type    Optional job type (the "job" column) to match (empty means any).
# ------------------------------------------------------------------------------
_knit_job_reset_apply() {
    local states_csv="$1" max_retries="$2"
    local sel_id="$3" sel_group="$4" sel_type="$5"

    local jobs_ident id_ident group_ident retries_ident
    _knit_db_sql_ident jobs_ident "${_KNIT_JOBS_TABLE}"
    _knit_db_sql_ident id_ident "id"
    _knit_db_sql_ident group_ident "group"
    _knit_db_sql_ident retries_ident "retries"

    local -a conds=()
    local states_in
    states_in="$(_knit_job_in_clause "state" "${states_csv}")"
    conds+=("${states_in}")
    local esc
    if [[ -n "${sel_id}" ]]; then
        _knit_sql_escape esc "${sel_id}"
        conds+=("${id_ident}='${esc}'")
    fi
    if [[ -n "${sel_group}" ]]; then
        _knit_sql_escape esc "${sel_group}"
        conds+=("${group_ident}='${esc}'")
    fi
    if [[ -n "${sel_type}" ]]; then
        _knit_sql_escape esc "${sel_type}"
        conds+=("job='${esc}'")
    fi
    local where
    printf -v where '%s AND ' "${conds[@]}"
    where="${where% AND }"

    local reset_count=0 skipped=0
    local id state retries
    while IFS=$'\x1f' read -r id state retries; do
        [[ -z "${id}" ]] && continue
        retries="${retries:-0}"
        if [[ -n "${max_retries}" ]] && (( retries >= max_retries )); then
            knit_warning "Job \"%s\" has been retried %s time(s) (cap %s); leaving it \"%s\"." \
                "${id}" "${retries}" "${max_retries}" "${state}"
            skipped=$(( skipped + 1 ))
            continue
        fi
        _knit_job_reset_one "${id}" "${retries}"
        printf '%s\n' "${id}"
        reset_count=$(( reset_count + 1 ))
    done < <(_knit_sqlite3 -separator $'\x1f' \
        "SELECT ${id_ident}, state, COALESCE(${retries_ident}, 0) \
           FROM ${jobs_ident} WHERE ${where} ORDER BY ${id_ident} ASC;")

    if (( skipped > 0 )); then
        knit_info "Reset %s job(s) to prepared; skipped %s at the retry cap." \
            "${reset_count}" "${skipped}"
    else
        knit_info "Reset %s job(s) to prepared." "${reset_count}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_job_reset()
#
# Entry point for the `job reset` CLI command. Re-queue terminal-failed jobs
# (state "killed" or "failed") back to "prepared" so a later `submit drain`
# retries them. The source states default to "killed,failed" and are restricted
# to those two (plus "completed" under --force) by _knit_job_reset_validate_states;
# the non-terminal "running"/"submitting" are never touched (orphan reclaim is a
# separate feature). The id / group / type selectors narrow which jobs match (all
# AND-ed), and --max-retries caps how many times a repeatedly-failing job is
# retried. The actual re-queue is done by the shared worker _knit_job_reset_apply.
#
# Usage:
# ```
# ./exp.sh job reset [--id <uuid>] [--group <g>] [--type <job>] \
#     [--state killed,failed] [--max-retries <n>] [--force]
# ```
# ------------------------------------------------------------------------------
_knit_job_reset() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local id group type states max_retries force
    id=$(knit_get_parameter "id" "$@") || id=""
    group=$(knit_get_parameter "group" "$@") || group=""
    type=$(knit_get_parameter "type" "$@") || type=""
    states=$(knit_get_parameter "state" "$@") || states="killed,failed"
    max_retries=$(knit_get_parameter "max-retries" "$@") || max_retries=""
    force=$(knit_get_parameter "force" "$@") || force="false"

    _knit_job_reset_validate_states "${states}" "${force}"

    if [[ -n "${max_retries}" ]] && (( max_retries < 1 )); then
        knit_fatal "job reset: --max-retries must be 1 or greater (got \"${max_retries}\")."
    fi

    _knit_job_reset_apply "${states}" "${max_retries}" "${id}" "${group}" "${type}"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_reconcile_set_state()
#
# Update a job row to a new state using a conditional SQL UPDATE that only
# matches rows still in an active state (running or submitting). This guard
# prevents a reconcile write from overwriting a terminal state that the job's
# own kill trap wrote a moment earlier: whichever writer runs second finds the
# row already left active states and makes no change.
#
# Route through _knit_sqlite3_write (the flock serializer) so the conditional
# check and the write are atomic with respect to other concurrent writers.
#
# @param[in] id        Job UUID.
# @param[in] new_state Terminal state to record (completed, failed, or killed).
# ------------------------------------------------------------------------------
_knit_job_reconcile_set_state() {
    local id="$1" new_state="$2"
    local esc_id esc_state
    _knit_sql_escape esc_id "${id}"
    _knit_sql_escape esc_state "${new_state}"
    _knit_sqlite3_write \
        "UPDATE jobs SET state = '${esc_state}' WHERE id = '${esc_id}' AND state IN ('running','submitting');"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_reconcile_apply()
#
# Shared worker behind `job reconcile` and `submit drain --reconcile`. For each
# job row in state running or submitting that matches the optional selectors,
# ask the scheduler for the job's true state and move the row to the correct
# terminal state when the scheduler confirms the job has stopped. A running
# verdict leaves the row unchanged. An unknown verdict (the scheduler has no
# record of a job the row calls active) is mapped to killed.
#
# The .job.id-less rule: when the job directory has no launcher id file, a
# submitting row without an explicit --id is skipped with a warning (a live
# drainer may be mid-dispatch); any other active row without a launcher id
# (including a running row or a submitting row addressed by explicit --id) is
# treated as unknown, which maps to killed.
#
# Each changed row is printed to stdout as "<id> <new_state>". Under dry-run the
# same output is produced but no write is made. A summary count goes to stderr.
# Reconciling nothing is not an error.
#
# @param[in] dry_run   "true" to report without writing.
# @param[in] sel_id    Optional job UUID to match (empty means any).
# @param[in] sel_group Optional group to match (empty means any).
# @param[in] sel_type  Optional job type to match (empty means any).
# ------------------------------------------------------------------------------
_knit_job_reconcile_apply() {
    local dry_run="$1" sel_id="$2" sel_group="$3" sel_type="$4"

    local jobs_ident id_ident group_ident
    _knit_db_sql_ident jobs_ident "${_KNIT_JOBS_TABLE}"
    _knit_db_sql_ident id_ident "id"
    _knit_db_sql_ident group_ident "group"

    local -a conds=()
    conds+=("state IN ('running','submitting')")
    local esc
    if [[ -n "${sel_id}" ]]; then
        _knit_sql_escape esc "${sel_id}"
        conds+=("${id_ident} = '${esc}'")
    fi
    if [[ -n "${sel_group}" ]]; then
        _knit_sql_escape esc "${sel_group}"
        conds+=("${group_ident} = '${esc}'")
    fi
    if [[ -n "${sel_type}" ]]; then
        _knit_sql_escape esc "${sel_type}"
        conds+=("job = '${esc}'")
    fi
    local where
    printf -v where '%s AND ' "${conds[@]}"
    where="${where% AND }"

    local changed=0 left_running=0
    local row_id row_state jobdir verdict jobid backend new_state
    while IFS=$'\x1f' read -r row_id row_state; do
        [[ -z "${row_id}" ]] && continue

        jobdir="$(_knit_job_dir "${row_id}")"
        verdict=""
        new_state=""

        if [[ ! -f "${jobdir}/.job.id" ]]; then
            if [[ -n "${sel_id}" ]]; then
                verdict="unknown"
            elif [[ "${row_state}" == "submitting" ]]; then
                knit_warning \
                    "Job \"%s\" is submitting with no launcher id; skipping (a drainer may be mid-dispatch)." \
                    "${row_id}"
                continue
            else
                verdict="unknown"
            fi
        else
            _knit_jobid_read backend jobid "${jobdir}"
            _knit_sched_status verdict "${backend}" "${jobid}"
        fi

        case "${verdict}" in
            running)
                left_running=$(( left_running + 1 ))
                continue
                ;;
            completed)      new_state="completed" ;;
            failed)         new_state="failed" ;;
            killed|unknown) new_state="killed" ;;
        esac

        printf '%s %s\n' "${row_id}" "${new_state}"
        if [[ "${dry_run}" != "true" ]]; then
            _knit_job_reconcile_set_state "${row_id}" "${new_state}"
        fi
        changed=$(( changed + 1 ))
    done < <(_knit_sqlite3 -separator $'\x1f' \
        "SELECT ${id_ident}, state FROM ${jobs_ident} WHERE ${where} ORDER BY ${id_ident} ASC;")

    knit_info "Reconciled %s job(s); left %s running." "${changed}" "${left_running}"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_reconcile()
#
# Entry point for the `job reconcile` CLI command. For each job whose row is in
# state running or submitting, ask the scheduler for its true fate and correct
# the row to the right terminal state when the scheduler confirms the job has
# stopped. A job the scheduler still reports as active is left unchanged.
#
# With no selectors the command walks all active jobs. The id / group / type
# selectors AND-ed together narrow the scope. An empty match is a no-op (not an
# error). With --dry-run each would-be change is reported but no write is made.
#
# Usage:
# ```
# ./exp.sh job reconcile [--id <uuid>] [--group <g>] [--type <job>] [--dry-run]
# ```
# ------------------------------------------------------------------------------
_knit_job_reconcile() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local id group type dry_run
    id=$(knit_get_parameter "id" "$@") || id=""
    group=$(knit_get_parameter "group" "$@") || group=""
    type=$(knit_get_parameter "type" "$@") || type=""
    dry_run=$(knit_get_parameter "dry-run" "$@") || dry_run="false"

    _knit_job_reconcile_apply "${dry_run}" "${id}" "${group}" "${type}"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_reconstruct_args_from_db_row()
#
# Append CLI arguments reconstructing a command's recorded parameters from one
# row of a table, so a past invocation can be replayed. Iteration is driven by
# the command's declared schema (not the raw table columns) so that only genuine
# parameters are emitted and outputs are ignored: each required or optional
# parameter with a non-empty recorded value is appended as "--name value", and
# each flag recorded as "true" is appended as a bare "--name". A column named in
# the space-separated skip list is left out (e.g. "setup", handled specially by
# the caller). A parameter whose column is absent from the table is skipped, so a
# job whose per-job table predates a newly added parameter still replays.
#
# @param[out] out_name Name of the array variable to append the reconstructed args to.
# @param[in] cmd      Mangled command whose schema drives the reconstruction.
# @param[in] table    Table holding the recorded row.
# @param[in] id       Value of the row's "id" column.
# @param[in] skip     Space-separated normalized names to omit.
# ------------------------------------------------------------------------------
_knit_job_reconstruct_args_from_db_row() {
    # shellcheck disable=SC2178 # nameref to the caller's args array
    local -n _out="$1"
    local cmd="$2" table="$3" id="$4" skip=" $5 "
    local escaped
    _knit_sql_escape escaped "${id}"

    # Columns actually present in the table (a parameter may have been added to
    # the command after this row was recorded).
    local -A cols=()
    local _cid col _rest esc_table q_table
    _knit_sql_escape esc_table "${table}"
    _knit_sql_quote_identifier q_table "${table}"
    while IFS='|' read -r _cid col _rest; do
        [[ -n "${col}" ]] && cols["${col}"]=1
    done < <(_knit_sqlite3 "PRAGMA table_info('${esc_table}');")

    local group name value q_name
    for group in required optional; do
        while IFS= read -r name; do
            [[ -z "${name}" ]] && continue
            [[ "${skip}" == *" ${name} "* ]] && continue
            [[ -v cols["${name}"] ]] || continue
            _knit_sql_quote_identifier q_name "${name}"
            value=$(_knit_sqlite3 \
                "SELECT ${q_name} FROM ${q_table} WHERE id = '${escaped}';")
            [[ -n "${value}" ]] && _out+=("--${name}" "${value}")
        done < <(_knit_set_iter "_KNIT_CMD_${cmd}_${group}" | sort)
    done

    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        [[ "${skip}" == *" ${name} "* ]] && continue
        [[ -v cols["${name}"] ]] || continue
        _knit_sql_quote_identifier q_name "${name}"
        value=$(_knit_sqlite3 \
            "SELECT ${q_name} FROM ${q_table} WHERE id = '${escaped}';")
        [[ "${value}" == "true" ]] && _out+=("--${name}")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_flags" | sort)
}

# ------------------------------------------------------------------------------
# @fn _knit_job_resubmit()
#
# Re-submit an existing job by replaying what was recorded for it. The jobs row
# supplies the setup path, the job name (the "job" output column, used as the
# token after --) and the submission options; the per-job <jobname> table
# supplies the arguments passed to the job itself. These are reconstructed into a
# fresh `knit submit --setup <setup> [options] -- <job> [args]` invocation, which
# mints a new job UUID — the old id is never reused.
#
# The submission options and job arguments are rebuilt by
# _knit_job_reconstruct_args_from_db_row from each command's declared schema, so bookkeeping
# columns (id, state, and the "job" name itself) and job outputs are left out;
# the setup path is skipped there too and passed as --setup instead. A job that
# was submitted but never ran has no per-job table, so it is resubmitted with its
# submission options only. An unknown id is a fatal error.
# ------------------------------------------------------------------------------
_knit_job_resubmit() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local id
    id=$(knit_get_parameter "id" "$@")
    local escaped
    _knit_sql_escape escaped "${id}"

    # The submission row must exist; its "job" column names both the dispatch
    # target and the per-job parameter table.
    local row job_name
    row="$(_knit_sqlite3 "SELECT id, job FROM jobs WHERE id = '${escaped}';")"
    if [[ -z "${row}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    IFS='|' read -r _ job_name <<< "${row}"

    # Rebuild the submit options from the jobs row (setup is passed as --setup,
    # not as a generic option).
    local -a submit_opts=()
    local setup
    setup="$(_knit_sqlite3 "SELECT setup FROM jobs WHERE id = '${escaped}';")"
    [[ -n "${setup}" ]] && submit_opts+=("--setup" "${setup}")
    _knit_job_reconstruct_args_from_db_row submit_opts \
        "submit" "${_KNIT_JOBS_TABLE}" "${id}" "setup"

    # Rebuild the job arguments from the per-job table, when the job has run at
    # least once (the table is created lazily on first run) and is a registered
    # job command whose schema we can consult.
    local -a job_args=()
    local job_cmd
    _knit_command_mangle job_cmd "submit:${job_name}"
    if [[ -n "${job_name}" ]] && _knit_set_find _KNIT_COMMANDS "${job_cmd}"; then
        local cnt esc_job_name
        _knit_sql_escape esc_job_name "${job_name}"
        cnt="$(_knit_sqlite3 \
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${esc_job_name}';")"
        if [[ "${cnt}" -ne 0 ]]; then
            _knit_job_reconstruct_args_from_db_row job_args \
                "${job_cmd}" "${job_name}" "${id}" ""
        fi
    fi

    # Registered spelling of the job (the "job" column stores the canonical form).
    local job_display_var="_KNIT_CMD_${job_cmd}_display"
    local job_display="${!job_display_var:-${job_name}}"
    knit_info "Resubmitting job \"${id}\" as \"${job_display}\"."
    _knit_invoke_command "submit" "${submit_opts[@]}" -- "${job_name}" "${job_args[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_show()
#
# Show everything recorded about one job. Two rows describe a job: the submission
# row in the jobs table (the scheduler options passed to `knit submit` plus the
# lifecycle state), and, once the job has actually run, the row it recorded in
# its own per-job table (the arguments passed to the job after --). The per-job
# table is named after the job, read from the submission row's "job" column.
#
# Text mode prints two labelled, column-aligned sections (Submission and
# Parameters). --json emits { "submission": <row>, "parameters": <row> }, each a
# single object (or null when absent), built from sqlite's -json output merged
# with the bundled jq. The per-job table exists only after the job has run at
# least once; until then the parameters section is empty (null in JSON).
#
# An unknown id is a fatal error.
# ------------------------------------------------------------------------------
_knit_job_show() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local id json
    id=$(knit_get_parameter "id" "$@")
    json=$(knit_get_parameter "json" "$@") || json="false"
    local escaped
    _knit_sql_escape escaped "${id}"

    # The submission row must exist; its "job" column names the per-job table.
    # An empty result means no such row (a present row always has a non-empty
    # id); split sqlite's default "|"-separated columns to read the job name.
    local row job_name
    row="$(_knit_sqlite3 "SELECT id, job FROM jobs WHERE id = '${escaped}';")"
    if [[ -z "${row}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    IFS='|' read -r _ job_name <<< "${row}"
    local q_job_name=""
    [[ -n "${job_name}" ]] && _knit_sql_quote_identifier q_job_name "${job_name}"

    # The per-job table is created lazily on the job's first invocation, so it
    # may not exist yet for a job that was submitted but has not run.
    local param_table_exists=0
    if [[ -n "${job_name}" ]]; then
        local cnt esc_job_name
        _knit_sql_escape esc_job_name "${job_name}"
        cnt="$(_knit_sqlite3 \
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${esc_job_name}';")"
        [[ "${cnt}" -ne 0 ]] && param_table_exists=1
    fi

    if [[ "${json}" == "true" ]]; then
        local sub_json param_json
        sub_json="$(_knit_sqlite3 -json \
            "SELECT * FROM jobs WHERE id = '${escaped}';")"
        [[ -z "${sub_json}" ]] && sub_json="[]"
        param_json="[]"
        if [[ "${param_table_exists}" -eq 1 ]]; then
            param_json="$(_knit_sqlite3 -json \
                "SELECT * FROM ${q_job_name} WHERE id = '${escaped}';")"
            [[ -z "${param_json}" ]] && param_json="[]"
        fi
        # shellcheck disable=SC2016 # $submission/$parameters are jq variables, not shell
        knit_jq -n \
            --argjson submission "${sub_json}" \
            --argjson parameters "${param_json}" \
            '{submission: ($submission[0] // null), parameters: ($parameters[0] // null)}'
        return 0
    fi

    printf 'Submission:\n'
    _knit_sqlite3 -header -column \
        "SELECT * FROM jobs WHERE id = '${escaped}';"
    printf '\nParameters:\n'
    if [[ "${param_table_exists}" -eq 1 ]]; then
        _knit_sqlite3 -header -column \
            "SELECT * FROM ${q_job_name} WHERE id = '${escaped}';"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_job_show_file()
#
# Print the contents of one of the files in a job's working directory. Shared by
# the `job show stdout`, `job show stderr` and `job show script` subcommands. The
# job must exist in the jobs table (an unknown id is fatal), and the requested
# file must be present in the job's working directory (a missing file is fatal —
# for the output streams it usually means the job has not produced that output
# yet).
#
# @param[in] id       Job UUID.
# @param[in] filename Name of the file within the job directory (e.g. ".stdout",
#                 ".stderr", ".job.sh").
# @param[in] label    Human-readable name of the file for error messages (e.g.
#                 "stdout", "stderr", "script").
# ------------------------------------------------------------------------------
_knit_job_show_file() {
    local id="$1" filename="$2" label="$3"
    local found esc_id
    _knit_sql_escape esc_id "${id}"
    found="$(_knit_sqlite3 \
        "SELECT id FROM jobs WHERE id = '${esc_id}';")"
    if [[ -z "${found}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    local jobdir file
    jobdir="$(_knit_job_dir "${id}")"
    file="${jobdir}/${filename}"
    if [[ ! -f "${file}" ]]; then
        knit_fatal "No ${label} recorded for job \"${id}\" (${file} is missing)."
    fi
    cat "${file}"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_state_is_terminal()
#
# Succeed (return 0) if the job's recorded lifecycle state is terminal
# (completed, failed, or killed), meaning no more output will be written. Any
# other state (including an unknown id, which yields an empty result) returns
# non-zero. Used by the follow loop as a backend-agnostic "job is done" signal.
#
# @param[in] id Job UUID.
# ------------------------------------------------------------------------------
_knit_job_state_is_terminal() {
    local state esc_id
    _knit_sql_escape esc_id "$1"
    state="$(_knit_sqlite3 \
        "SELECT state FROM jobs WHERE id = '${esc_id}';")"
    case "${state}" in
        completed|failed|killed) return 0 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_job_follow_file()
#
# Stream one of a job's output files live, like `tail -f`, and stop cleanly once
# the job finishes. Shared by `job show stdout --follow` and
# `job show stderr --follow`. An unknown id is fatal (as for the non-following
# form).
#
# Behaviour depends on the job's lifecycle state:
#   - Already terminal: nothing more will be written, so print the file once and
#     return (a missing file is fatal, exactly as `job show ${label}`).
#   - Still running: wait for the file to appear (it is created on the job's first
#     write), then follow it from the beginning. A bare `tail -f` would hang
#     forever after the job exits, so it runs in the background and is stopped
#     once the job's jobs-table row reaches a terminal state. That state is
#     polled rather than tied to a local pid so following works for remote
#     scheduler backends where the job runs on another node. If the job finishes
#     without ever producing the file, that is fatal (as for the non-following
#     form).
#
# @param[in] id       Job UUID.
# @param[in] filename Name of the file within the job directory (".stdout"/".stderr").
# @param[in] label    Human-readable name of the file for error messages.
# ------------------------------------------------------------------------------
_knit_job_follow_file() {
    local id="$1" filename="$2" label="$3"
    local found esc_id
    _knit_sql_escape esc_id "${id}"
    found="$(_knit_sqlite3 \
        "SELECT id FROM jobs WHERE id = '${esc_id}';")"
    if [[ -z "${found}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    local jobdir file
    jobdir="$(_knit_job_dir "${id}")"
    file="${jobdir}/${filename}"

    # A finished job has nothing left to stream: print what it captured and stop.
    if _knit_job_state_is_terminal "${id}"; then
        if [[ ! -f "${file}" ]]; then
            knit_fatal "No ${label} recorded for job \"${id}\" (${file} is missing)."
        fi
        cat "${file}"
        return 0
    fi

    # Wait for the stream file to be created, unless the job finishes first
    # without ever writing it.
    while [[ ! -f "${file}" ]]; do
        if _knit_job_state_is_terminal "${id}"; then
            knit_fatal "No ${label} recorded for job \"${id}\" (${file} is missing)."
        fi
        sleep "${_KNIT_SCHED_POLL_INTERVAL}"
    done

    # Follow the file in the background; stop once the job reaches a terminal
    # state.
    tail -n +1 -f "${file}" &
    local tail_pid=$!
    while ! _knit_job_state_is_terminal "${id}"; do
        sleep "${_KNIT_SCHED_POLL_INTERVAL}"
    done
    # Give tail one more read cycle to flush output written just before the job
    # finished, then stop it.
    sleep "${_KNIT_SCHED_POLL_INTERVAL}"
    kill "${tail_pid}" 2>/dev/null
    wait "${tail_pid}" 2>/dev/null
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_job_show_stdout()
#
# Print the standard output a job captured while running (the .stdout file in the
# job's working directory). An unknown id or an absent file is a fatal error.
# With --follow, stream the output live and stop once the job finishes (see
# _knit_job_follow_file).
# ------------------------------------------------------------------------------
_knit_job_show_stdout() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local id follow
    id=$(knit_get_parameter "id" "$@")
    follow=$(knit_get_parameter "follow" "$@") || follow="false"
    if [[ "${follow}" == "true" ]]; then
        _knit_job_follow_file "${id}" ".stdout" "stdout"
    else
        _knit_job_show_file "${id}" ".stdout" "stdout"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_job_show_stderr()
#
# Print the standard error a job captured while running (the .stderr file in the
# job's working directory). An unknown id or an absent file is a fatal error.
# With --follow, stream the output live and stop once the job finishes (see
# _knit_job_follow_file).
# ------------------------------------------------------------------------------
_knit_job_show_stderr() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local id follow
    id=$(knit_get_parameter "id" "$@")
    follow=$(knit_get_parameter "follow" "$@") || follow="false"
    if [[ "${follow}" == "true" ]]; then
        _knit_job_follow_file "${id}" ".stderr" "stderr"
    else
        _knit_job_show_file "${id}" ".stderr" "stderr"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_job_show_script()
#
# Print the batch script knit generated for a job (the .job.sh file in the job's
# working directory). An unknown id or an absent file is a fatal error.
# ------------------------------------------------------------------------------
_knit_job_show_script() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    _knit_job_show_file "$(knit_get_parameter "id" "$@")" ".job.sh" "script"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_discover()
#
# Register the job subcommands (status / list / wait / cancel / resubmit / show,
# and show's own stdout / stderr / script). Called lazily by the framework the
# first time a job subcommand is resolved, listed in "--help", or walked by
# "describe". "job:show" is registered before its own children so the parent
# exists first.
#
# @param[in] parent The parent command's display name (unused).
# ------------------------------------------------------------------------------
_knit_job_discover() {
    knit_register "job:status" _knit_job_status "Print the current lifecycle state of a job."
    _knit_is_builtin
    knit_with_required "id:string" "Job UUID."
    knit_done

    knit_register "job:list" _knit_job_list "List submitted jobs."
    _knit_is_builtin
    knit_with_optional "status:string" "" "Only list jobs in this lifecycle state."
    knit_with_optional "setup:string" "" \
        "Only list jobs whose setup is one of these (comma-separated) paths."
    knit_with_optional "types:string" "" \
        "Only list jobs of these (comma-separated) job types."
    knit_with_flag "no-setup" "Include jobs that have no setup."
    knit_with_flag "json" "Emit the listing as a JSON array."
    knit_done

    knit_register "job:wait" _knit_job_wait "Wait for one or more jobs to reach a terminal state."
    _knit_is_builtin
    knit_with_required "id:string" "Job UUID, or a comma-separated list of job UUIDs to wait for."
    knit_done

    knit_register "job:cancel" _knit_job_cancel "Cancel a running job."
    _knit_is_builtin
    knit_with_required "id:string" "Job UUID."
    knit_done

    knit_register "job:reset" _knit_job_reset \
        "Re-queue failed or killed jobs back to prepared for a retry."
    _knit_is_builtin
    knit_with_optional "id:string" "" "Reset the job with this UUID."
    knit_with_optional "group:string" "" "Reset jobs in this group."
    knit_with_optional "type:string" "" "Reset jobs of this type (the job name)."
    knit_with_optional "state:string" "killed,failed" \
        "Comma-separated source states to reset (from killed, failed; completed needs --force)."
    knit_with_optional "max-retries:integer" "" \
        "Skip (and warn about) a job whose retries count already reached this value."
    knit_with_flag "force" "Also allow resetting a completed job (a deliberate redo)."
    knit_done

    knit_register "job:reconcile" _knit_job_reconcile \
        "Correct stuck running or submitting jobs to their true terminal state by querying the scheduler."
    _knit_is_builtin
    knit_with_optional "id:string" "" "Reconcile only the job with this UUID."
    knit_with_optional "group:string" "" "Reconcile jobs in this group."
    knit_with_optional "type:string" "" "Reconcile jobs of this type (the job name)."
    knit_with_flag "dry-run" "Report what each row would become; write nothing."
    knit_done

    knit_register "job:resubmit" _knit_job_resubmit "Re-run a job reusing its recorded parameters."
    _knit_is_builtin
    knit_with_required "id:string" "Job UUID."
    knit_done

    knit_register "job:show" _knit_job_show "Show a job's submission options and job parameters."
    _knit_is_builtin
    knit_with_required "id:string" "Job UUID."
    knit_with_flag "json" "Emit the result as JSON."
    knit_done

    knit_register "job:show:stdout" _knit_job_show_stdout "Print a job's captured standard output."
    _knit_is_builtin
    knit_with_required "id:string" "Job UUID."
    knit_with_flag "follow" "Follow the stream as it grows, like tail -f."
    knit_done

    knit_register "job:show:stderr" _knit_job_show_stderr "Print a job's captured standard error."
    _knit_is_builtin
    knit_with_required "id:string" "Job UUID."
    knit_with_flag "follow" "Follow the stream as it grows, like tail -f."
    knit_done

    knit_register "job:show:script" _knit_job_show_script "Print a job's generated batch script."
    _knit_is_builtin
    knit_with_required "id:string" "Job UUID."
    knit_done
}
