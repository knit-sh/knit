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
