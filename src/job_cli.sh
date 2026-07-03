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
