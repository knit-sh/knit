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
_knit_is_builtin
knit_done

# ------------------------------------------------------------------------------
# Print the current lifecycle state of a job.
# ------------------------------------------------------------------------------
knit_register _knit_job_status "job:status" "Print the current lifecycle state of a job."
_knit_is_builtin
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
    local state esc_id
    _knit_sql_escape esc_id "${id}"
    state=$(_knit_sqlite3 \
        "SELECT state FROM jobs WHERE id = '${esc_id}';")
    if [[ -z "${state}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    printf '%s\n' "${state}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_job_in_clause()
#
# Build a SQL "<column> IN (...)" condition from a comma-separated list of
# values, each escaped as a single-quoted literal. Empty entries are dropped;
# nothing is printed when the list has no non-empty value, so the caller can test
# for an empty result and skip the condition entirely.
#
# @param column Column name to match (interpolated verbatim, so a trusted name).
# @param csv    Comma-separated list of values.
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
# List submitted jobs, optionally filtered by state, setup, or type.
# ------------------------------------------------------------------------------
knit_register _knit_job_list "job:list" "List submitted jobs."
_knit_is_builtin
knit_with_optional "status:string" "" "Only list jobs in this lifecycle state."
knit_with_optional "setup:string" "" \
    "Only list jobs whose setup is one of these (comma-separated) paths."
knit_with_optional "types:string" "" \
    "Only list jobs of these (comma-separated) job types."
knit_with_flag "no-setup" "Include jobs that have no setup."
knit_with_flag "json" "Emit the listing as a JSON array."
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
    local setup esc_id
    _knit_sql_escape esc_id "${id}"
    setup="$(_knit_sqlite3 \
        "SELECT setup FROM jobs WHERE id = '${esc_id}';")"
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
_knit_is_builtin
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
    _knit_sql_escape escaped "${id}"

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
    local backend
    _knit_sched_backend backend
    _knit_sched_wait "${backend}" "${jobid}"

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
        sleep "${_KNIT_SCHED_POLL_INTERVAL}"
    done

    # The scheduler finished the job but knit never recorded a terminal state
    # (e.g. status tracking was disabled or failed). Report what we have.
    knit_warning "Job \"${id}\" is no longer running but its recorded state is \"${state}\"."
    printf '%s\n' "${state}"
    return 0
}
knit_done

# ------------------------------------------------------------------------------
# Cancel a running job through its scheduler backend.
# ------------------------------------------------------------------------------
knit_register _knit_job_cancel "job:cancel" "Cancel a running job."
_knit_is_builtin
knit_with_required "id:string" "Job UUID."
# ------------------------------------------------------------------------------
# @fn _knit_job_cancel()
#
# Cancel a job that is still running by asking its scheduler backend to terminate
# it, then recording the job's row as "killed". The backend job id is read from
# the job directory's .job.id (as `job wait` does) and handed to the backend's
# cancel primitive (local -> kill, slurm -> scancel, pbs -> qdel).
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
    # Already finished: there is nothing to cancel.
    case "${state}" in
        completed|killed)
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
    IFS= read -r jobid < "${jobdir}/.job.id"

    local backend
    _knit_sched_backend backend
    _knit_sched_cancel "${backend}" "${jobid}"
    _knit_db_update_row "${_KNIT_JOBS_TABLE}" "${id}" "state=killed"
    knit_info "Cancelled job \"${id}\"."
}
knit_done

# ------------------------------------------------------------------------------
# Remove a job's working directory and its lifecycle row.
# ------------------------------------------------------------------------------
knit_register _knit_job_rm "job:rm" "Remove a job's working directory and lifecycle row."
_knit_is_builtin
knit_with_required "id:string" "Job UUID."
knit_with_flag "force" "Remove even if the job is still running."
# ------------------------------------------------------------------------------
# @fn _knit_job_rm()
#
# Delete a job: remove its working directory (_knit_job_dir) and its row in the
# jobs table. The per-job <jobname> parameter table is left untouched, since it
# is shared across every invocation of that job.
#
# A job that has not reached a terminal state (completed or killed) is still
# potentially running; removing its directory out from under it would leave a
# live process writing into a deleted tree. Such a job is refused unless --force
# is given, and the message suggests cancelling it first. An unknown id is fatal.
# ------------------------------------------------------------------------------
_knit_job_rm() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local id force
    id=$(knit_get_parameter "id" "$@")
    force=$(knit_get_parameter "force" "$@") || force="false"
    local escaped
    _knit_sql_escape escaped "${id}"

    local state
    state="$(_knit_sqlite3 "SELECT state FROM jobs WHERE id = '${escaped}';")"
    if [[ -z "${state}" ]]; then
        knit_fatal "No job found with id \"${id}\"."
    fi
    # A non-terminal job may still be running; refuse to delete it unless forced.
    case "${state}" in
        completed|killed) ;;
        *)
            if [[ "${force}" != "true" ]]; then
                knit_fatal "Job \"${id}\" is still ${state}; cancel it first (${KNIT_SCRIPT_NAME} job cancel --id ${id}) or pass --force."
            fi
            ;;
    esac

    # Resolve the directory while the row still exists (the setup path is read
    # from it), then remove the tree and drop the row.
    local jobdir
    jobdir="$(_knit_job_dir "${id}")"
    rm -rf "${jobdir}"
    _knit_sqlite3_write "DELETE FROM jobs WHERE id = '${escaped}';"
    knit_info "Removed job \"${id}\"."
}
knit_done

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
# @param out_name Name of the array variable to append the reconstructed args to.
# @param cmd      Mangled command whose schema drives the reconstruction.
# @param table    Table holding the recorded row.
# @param id       Value of the row's "id" column.
# @param skip     Space-separated normalized names to omit.
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
# Re-run a job reusing the parameters recorded for a previous run.
# ------------------------------------------------------------------------------
knit_register _knit_job_resubmit "job:resubmit" "Re-run a job reusing its recorded parameters."
_knit_is_builtin
knit_with_required "id:string" "Job UUID."
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
    job_cmd=$(_knit_command_mangle "submit:${job_name}")
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

    knit_info "Resubmitting job \"${id}\" as \"${job_name}\"."
    _knit_invoke_command "submit" "${submit_opts[@]}" -- "${job_name}" "${job_args[@]}"
}
knit_done

# ------------------------------------------------------------------------------
# Show a job's submission options together with its job parameters.
# ------------------------------------------------------------------------------
knit_register _knit_job_show "job:show" "Show a job's submission options and job parameters."
_knit_is_builtin
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
            "SELECT * FROM ${q_job_name} WHERE id = '${escaped}';"
    fi
}
knit_done

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
# @param id       Job UUID.
# @param filename Name of the file within the job directory (e.g. ".stdout",
#                 ".stderr", ".job.sh").
# @param label    Human-readable name of the file for error messages (e.g.
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
# (completed or killed), meaning no more output will be written. Any other state
# (including an unknown id, which yields an empty result) returns non-zero. Used
# by the follow loop as a backend-agnostic "job is done" signal.
#
# @param id Job UUID.
# ------------------------------------------------------------------------------
_knit_job_state_is_terminal() {
    local state esc_id
    _knit_sql_escape esc_id "$1"
    state="$(_knit_sqlite3 \
        "SELECT state FROM jobs WHERE id = '${esc_id}';")"
    case "${state}" in
        completed|killed) return 0 ;;
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
# @param id       Job UUID.
# @param filename Name of the file within the job directory (".stdout"/".stderr").
# @param label    Human-readable name of the file for error messages.
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
# Print a job's captured standard output.
# ------------------------------------------------------------------------------
knit_register _knit_job_show_stdout "job:show:stdout" "Print a job's captured standard output."
_knit_is_builtin
knit_with_required "id:string" "Job UUID."
knit_with_flag "follow" "Follow the stream as it grows, like tail -f."
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
knit_done

# ------------------------------------------------------------------------------
# Print a job's captured standard error.
# ------------------------------------------------------------------------------
knit_register _knit_job_show_stderr "job:show:stderr" "Print a job's captured standard error."
_knit_is_builtin
knit_with_required "id:string" "Job UUID."
knit_with_flag "follow" "Follow the stream as it grows, like tail -f."
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
knit_done

# ------------------------------------------------------------------------------
# Print a job's generated batch script.
# ------------------------------------------------------------------------------
knit_register _knit_job_show_script "job:show:script" "Print a job's generated batch script."
_knit_is_builtin
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
    _knit_job_show_file "$(knit_get_parameter "id" "$@")" ".job.sh" "script"
}
knit_done
