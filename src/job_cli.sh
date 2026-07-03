#!/bin/bash

## @file job_cli.sh
##
## Commands for inspecting submitted jobs (`job list`, `job status`, `job wait`,
## `job show`, ...). Job *submission* lives in `job.sh`; this file holds the
## read-side commands that query the `jobs` table and a job's working directory.

# ------------------------------------------------------------------------------
# Registration of the job command group.
# ------------------------------------------------------------------------------
knit_register knit_empty job "Inspect submitted jobs."
knit_done

# ------------------------------------------------------------------------------
# Print the current lifecycle state of a job.
# ------------------------------------------------------------------------------
knit_register _knit_job_status "job:status" "Print the current lifecycle state of a job."
knit_with_required "id:string" "Job UUID."
# ------------------------------------------------------------------------------
# @fn _knit_job_status()
#
# Look up a job by its UUID in the jobs table and print its lifecycle state
# (e.g. submitted, running, completed, killed). An unknown id is an error.
# ------------------------------------------------------------------------------
_knit_job_status() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local id
    id=$(knit_get_parameter "id" "$@")
    local state
    state=$(_knit_sqlite3 \
        "SELECT state FROM jobs WHERE id = '$(_knit_sql_escape "${id}")';")
    if [[ -z "${state}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    printf '%s\n' "${state}"
}
knit_done

# ------------------------------------------------------------------------------
# List submitted jobs, optionally filtered by state or setup.
# ------------------------------------------------------------------------------
knit_register _knit_job_list "job:list" "List submitted jobs."
knit_with_optional "status:string" "" "Only list jobs in this lifecycle state."
knit_with_optional "setup:string" "" \
    "Only list jobs whose setup is one of these (comma-separated) paths."
knit_with_flag "no-setup" "Include jobs that have no setup."
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
# no setup filter is applied. The status filter (if any) is AND-ed with the
# setup filter. Output is rendered with aligned columns and a header row.
# ------------------------------------------------------------------------------
_knit_job_list() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local status setup no_setup
    status=$(knit_get_parameter "status" "$@")
    setup=$(knit_get_parameter "setup" "$@")
    no_setup=$(knit_get_parameter "no-setup" "$@") || no_setup="false"

    local -a conditions=()
    [[ -n "${status}" ]] \
        && conditions+=("state = '$(_knit_sql_escape "${status}")'")

    # Build the setup filter as the OR of --no-setup and the --setup IN list.
    local -a setup_conditions=()
    [[ "${no_setup}" == "true" ]] \
        && setup_conditions+=("setup IS NULL OR setup = ''")
    if [[ -n "${setup}" ]]; then
        local -a in_values=()
        local part
        local -a parts
        IFS=',' read -ra parts <<< "${setup}"
        for part in "${parts[@]}"; do
            [[ -z "${part}" ]] && continue
            in_values+=("'$(_knit_sql_escape "${part}")'")
        done
        if [[ "${#in_values[@]}" -gt 0 ]]; then
            local in_list
            printf -v in_list '%s, ' "${in_values[@]}"
            setup_conditions+=("setup IN (${in_list%, })")
        fi
    fi
    if [[ "${#setup_conditions[@]}" -gt 0 ]]; then
        local setup_group
        printf -v setup_group '%s OR ' "${setup_conditions[@]}"
        conditions+=("(${setup_group% OR })")
    fi

    local statement="SELECT id, job, state FROM jobs"
    if [[ "${#conditions[@]}" -gt 0 ]]; then
        local where
        printf -v where ' AND %s' "${conditions[@]}"
        statement="${statement} WHERE ${where# AND }"
    fi
    statement="${statement} ORDER BY id;"

    _knit_sqlite3 -header -column "${statement}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_job_dir()
#
# Print the working directory of a job given its UUID. A job that used a setup
# lives at <setup>/jobs/<id>; a setup-less job lives at <experiment-root>/jobs/
# <id>, where the root is the .knit prefix with its /.knit suffix removed. The
# setup is read from the job's jobs-table row.
#
# @param id Job UUID.
# ------------------------------------------------------------------------------
_knit_job_dir() {
    local id="$1"
    local setup
    setup="$(_knit_sqlite3 \
        "SELECT setup FROM jobs WHERE id = '$(_knit_sql_escape "${id}")';")"
    if [[ -n "${setup}" ]]; then
        printf '%s\n' "${setup}/jobs/${id}"
    else
        printf '%s\n' "${_KNIT_PREFIX%/.knit}/jobs/${id}"
    fi
}

# ------------------------------------------------------------------------------
# Block until a job reaches a terminal lifecycle state.
# ------------------------------------------------------------------------------
knit_register _knit_job_wait "job:wait" "Wait for a job to reach a terminal state."
knit_with_required "id:string" "Job UUID."
# ------------------------------------------------------------------------------
# @fn _knit_job_wait()
#
# Block until a job finishes, then print its terminal lifecycle state; a "killed"
# state yields a non-zero exit so callers can detect failure.
#
# Rather than busy-polling the database, this blocks on the scheduler itself:
# once the job's row is not already terminal, it looks up the backend job id
# (.job.id in the job directory) and calls the backend's native wait
# (_knit_sched_wait), which returns when the scheduler stops running the job. The
# job's terminal state (completed/killed) is recorded by its compute-side
# callbacks over the shared filesystem; that write is read back afterwards, with
# a short reconciliation window since it may land a moment after the scheduler
# reports the job gone. An unknown id is a fatal error rather than an endless
# wait.
# ------------------------------------------------------------------------------
_knit_job_wait() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local id
    id=$(knit_get_parameter "id" "$@")
    local escaped
    escaped=$(_knit_sql_escape "${id}")

    local state
    state="$(_knit_sqlite3 "SELECT state FROM jobs WHERE id = '${escaped}';")"
    if [[ -z "${state}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    # Already finished: no need to involve the scheduler.
    case "${state}" in
        completed) printf '%s\n' "${state}"; return 0 ;;
        killed)    printf '%s\n' "${state}"; return 1 ;;
    esac

    # Block on the scheduler using the backend job id recorded at submit time.
    local jobdir jobid
    jobdir="$(_knit_job_dir "${id}")"
    if [[ ! -f "${jobdir}/.job.id" ]]; then
        knit_fatal "Job \"${id}\" has no recorded launcher id (${jobdir}/.job.id is missing)."
    fi
    IFS= read -r jobid < "${jobdir}/.job.id"
    _knit_sched_wait "$(_knit_sched_backend)" "${jobid}"

    # The scheduler reports the job gone; give the compute-side terminal-state
    # write a brief window to become visible, then report it.
    local tries=0
    while true; do
        state="$(_knit_sqlite3 "SELECT state FROM jobs WHERE id = '${escaped}';")"
        case "${state}" in
            completed) printf '%s\n' "${state}"; return 0 ;;
            killed)    printf '%s\n' "${state}"; return 1 ;;
        esac
        tries=$(( tries + 1 ))
        [[ "${tries}" -ge 5 ]] && break
        sleep "${__KNIT_SCHED_POLL_INTERVAL}"
    done

    # The scheduler finished the job but knit never recorded a terminal state
    # (e.g. status tracking was disabled or failed). Report what we have.
    knit_warning "Job \"${id}\" is no longer running but its recorded state is \"${state}\"."
    printf '%s\n' "${state}"
    return 0
}
knit_done

# ------------------------------------------------------------------------------
# Show a job's submission options together with its job parameters.
# ------------------------------------------------------------------------------
knit_register _knit_job_show "job:show" "Show a job's submission options and job parameters."
knit_with_required "id:string" "Job UUID."
knit_with_flag "json" "Emit the result as JSON."
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
    escaped=$(_knit_sql_escape "${id}")

    # The submission row must exist; its "job" column names the per-job table.
    # An empty result means no such row (a present row always has a non-empty
    # id); split sqlite's default "|"-separated columns to read the job name.
    local row job_name
    row="$(_knit_sqlite3 "SELECT id, job FROM jobs WHERE id = '${escaped}';")"
    if [[ -z "${row}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    IFS='|' read -r _ job_name <<< "${row}"

    # The per-job table is created lazily on the job's first invocation, so it
    # may not exist yet for a job that was submitted but has not run.
    local param_table_exists=0
    if [[ -n "${job_name}" ]]; then
        local cnt
        cnt="$(_knit_sqlite3 \
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$(_knit_sql_escape "${job_name}")';")"
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
                "SELECT * FROM $(_knit_sql_quote_identifier "${job_name}") WHERE id = '${escaped}';")"
            [[ -z "${param_json}" ]] && param_json="[]"
        fi
        # shellcheck disable=SC2016 # $submission/$parameters are jq variables, not shell
        _knit_jq -n \
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
            "SELECT * FROM $(_knit_sql_quote_identifier "${job_name}") WHERE id = '${escaped}';"
    fi
}
knit_done

# ------------------------------------------------------------------------------
# @fn __knit_job_show_file()
#
# Print the contents of one of the files in a job's working directory. Shared by
# the `job show stdout`, `job show stderr` and `job show script` subcommands. The
# job must exist in the jobs table (an unknown id is fatal), and the requested
# file must be present in the job's working directory (a missing file is fatal —
# for the output streams it usually means the job has not produced that output
# yet).
#
# @param id       Job UUID.
# @param filename Name of the file within the job directory (e.g. ".stdout",
#                 ".stderr", ".job.sh").
# @param label    Human-readable name of the file for error messages (e.g.
#                 "stdout", "stderr", "script").
# ------------------------------------------------------------------------------
__knit_job_show_file() {
    local id="$1" filename="$2" label="$3"
    local found
    found="$(_knit_sqlite3 \
        "SELECT id FROM jobs WHERE id = '$(_knit_sql_escape "${id}")';")"
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
# @fn __knit_job_state_is_terminal()
#
# Succeed (return 0) if the job's recorded lifecycle state is terminal
# (completed or killed), meaning no more output will be written. Any other state
# (including an unknown id, which yields an empty result) returns non-zero. Used
# by the follow loop as a backend-agnostic "job is done" signal.
#
# @param id Job UUID.
# ------------------------------------------------------------------------------
__knit_job_state_is_terminal() {
    local state
    state="$(_knit_sqlite3 \
        "SELECT state FROM jobs WHERE id = '$(_knit_sql_escape "$1")';")"
    case "${state}" in
        completed|killed) return 0 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn __knit_job_follow_file()
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
# @param id       Job UUID.
# @param filename Name of the file within the job directory (".stdout"/".stderr").
# @param label    Human-readable name of the file for error messages.
# ------------------------------------------------------------------------------
__knit_job_follow_file() {
    local id="$1" filename="$2" label="$3"
    local found
    found="$(_knit_sqlite3 \
        "SELECT id FROM jobs WHERE id = '$(_knit_sql_escape "${id}")';")"
    if [[ -z "${found}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    local jobdir file
    jobdir="$(_knit_job_dir "${id}")"
    file="${jobdir}/${filename}"

    # A finished job has nothing left to stream: print what it captured and stop.
    if __knit_job_state_is_terminal "${id}"; then
        if [[ ! -f "${file}" ]]; then
            knit_fatal "No ${label} recorded for job \"${id}\" (${file} is missing)."
        fi
        cat "${file}"
        return 0
    fi

    # Wait for the stream file to be created, unless the job finishes first
    # without ever writing it.
    while [[ ! -f "${file}" ]]; do
        if __knit_job_state_is_terminal "${id}"; then
            knit_fatal "No ${label} recorded for job \"${id}\" (${file} is missing)."
        fi
        sleep "${__KNIT_SCHED_POLL_INTERVAL}"
    done

    # Follow the file in the background; stop once the job reaches a terminal
    # state.
    tail -n +1 -f "${file}" &
    local tail_pid=$!
    while ! __knit_job_state_is_terminal "${id}"; do
        sleep "${__KNIT_SCHED_POLL_INTERVAL}"
    done
    # Give tail one more read cycle to flush output written just before the job
    # finished, then stop it.
    sleep "${__KNIT_SCHED_POLL_INTERVAL}"
    kill "${tail_pid}" 2>/dev/null
    wait "${tail_pid}" 2>/dev/null
    return 0
}

# ------------------------------------------------------------------------------
# Print a job's captured standard output.
# ------------------------------------------------------------------------------
knit_register _knit_job_show_stdout "job:show:stdout" "Print a job's captured standard output."
knit_with_required "id:string" "Job UUID."
knit_with_flag "follow" "Follow the stream as it grows, like tail -f."
# ------------------------------------------------------------------------------
# @fn _knit_job_show_stdout()
#
# Print the standard output a job captured while running (the .stdout file in the
# job's working directory). An unknown id or an absent file is a fatal error.
# With --follow, stream the output live and stop once the job finishes (see
# __knit_job_follow_file).
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
        __knit_job_follow_file "${id}" ".stdout" "stdout"
    else
        __knit_job_show_file "${id}" ".stdout" "stdout"
    fi
}
knit_done

# ------------------------------------------------------------------------------
# Print a job's captured standard error.
# ------------------------------------------------------------------------------
knit_register _knit_job_show_stderr "job:show:stderr" "Print a job's captured standard error."
knit_with_required "id:string" "Job UUID."
knit_with_flag "follow" "Follow the stream as it grows, like tail -f."
# ------------------------------------------------------------------------------
# @fn _knit_job_show_stderr()
#
# Print the standard error a job captured while running (the .stderr file in the
# job's working directory). An unknown id or an absent file is a fatal error.
# With --follow, stream the output live and stop once the job finishes (see
# __knit_job_follow_file).
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
        __knit_job_follow_file "${id}" ".stderr" "stderr"
    else
        __knit_job_show_file "${id}" ".stderr" "stderr"
    fi
}
knit_done

# ------------------------------------------------------------------------------
# Print a job's generated batch script.
# ------------------------------------------------------------------------------
knit_register _knit_job_show_script "job:show:script" "Print a job's generated batch script."
knit_with_required "id:string" "Job UUID."
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
    __knit_job_show_file "$(knit_get_parameter "id" "$@")" ".job.sh" "script"
}
knit_done
