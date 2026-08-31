#!/bin/bash

## @file job.sh

# ------------------------------------------------------------------------------
# @var _KNIT_JOBS
#
# Associative array mapping registered job names to 1. Used to validate that
# a job names passed to `knit submit` is known.
# ------------------------------------------------------------------------------
declare -gA _KNIT_JOBS

# ------------------------------------------------------------------------------
# @var _KNIT_JOBS_TABLE
#
# Name of the table recording every job and its lifecycle state. The row id is
# the job UUID; the "state" column moves submitted -> running -> completed, or
# -> killed when the scheduler terminates a job before it finishes. A submission
# the scheduler rejects never becomes a job and leaves no row at all (see
# _knit_submit_cleanup_rejected).
# ------------------------------------------------------------------------------
declare -g _KNIT_JOBS_TABLE
_KNIT_JOBS_TABLE="jobs"

# ------------------------------------------------------------------------------
# @var KNIT_JOB_PREFIX
#
# Public environment variable exported into a running job's environment: the
# absolute path of the job's own working directory, <job-root>/<uuid>. It is set
# by the generated job script (see _knit_sched_write_jobscript), which also makes
# it the process working directory, so a job body may either read it explicitly
# (e.g. to build an absolute output path) or rely on relative paths landing in it.
# It is unset outside a running job (on the login/submit side). The basename of
# this path is the job UUID, which is how compute-side callbacks recover their own
# row id in the jobs table.
# ------------------------------------------------------------------------------
declare -g KNIT_JOB_PREFIX

# ------------------------------------------------------------------------------
# @fn _knit_declare_submit_options()
#
# Declare the scheduler options shared by the `submit` and `prepare` dispatchers,
# so the two surfaces cannot drift. Must be called between knit_register and
# knit_done while registering either dispatcher. It declares the optional
# submission parameters (setup, name, job-name, account, project, queue, nodes,
# walltime, gpus-per-node) and the free-form --group label, plus the "job"
# dispatch marker and the "Jobs" subcommand title.
#
# Each dispatcher declares the rest itself: `submit` adds the submit-only --wait
# flag and owns the "jobs" table and its outputs; `prepare` declares neither a
# table nor outputs (it records under the `submit` identity, see
# _knit_prepare_build).
# ------------------------------------------------------------------------------
_knit_declare_submit_options() {
    knit_with_optional "setup:string" "" \
        "Name of the setup to use (required if the job declares a setup type)."
    # A stable, human-meaningful alias for this job instance under the job root:
    # `--name <name>` creates a symlink <job-root>/<name> -> <job-root>/<uuid>
    # and records the name in the jobs table. Distinct from --job-name below,
    # which is the scheduler-facing job name (#SBATCH --job-name / #PBS -N).
    knit_with_optional "name:string" "" \
        "Stable alias for this job (symlinked under the job root; must be unique)."
    # Identity. Empty defaults are the "not set" sentinel: _knit_sched_resolve
    # fills them from bootstrap metadata, the machine profile, or a fallback.
    knit_with_optional "job-name:string" "" \
        "Job name (default: the experiment script name)."
    knit_with_optional "account:string" "" \
        "Account (default: the __account__ metadata)."
    knit_with_optional "project:string" "" \
        "Project name (default: the __project__ metadata)."
    knit_with_optional "queue:string" "" \
        "Queue/partition (default: the site default queue)."
    # Resources. Knit allocates whole nodes exclusively: the per-node core count
    # is taken from the machine profile (or bootstrap detection), not requested
    # per submit, so there is no CPU option here.
    knit_with_optional "nodes:integer" "1" "Number of nodes."
    knit_with_optional "walltime:string" "" \
        "Wall-clock limit as HH:MM:SS (default: the site default)."
    knit_with_optional "gpus-per-node:integer" "0" "GPUs per node."
    # A free-form label grouping related jobs. An optional parameter is recorded
    # as its own "group" column automatically; it also drives "submit next
    # --group". "group" is a SQL keyword, quoted by _knit_db_sql_ident.
    knit_with_optional "group:string" "" \
        "Free-form label grouping related jobs (filter for \"submit next\")."
    knit_with_dispatch "job" "User-provided job command to execute"
    knit_with_subcommand_title "Jobs"
}

knit_register "submit" _knit_submit "Submit a job."
_knit_is_builtin
_knit_declare_submit_options
# Behaviour. Job stdout/stderr are always written to <job-dir>/.stdout and
# <job-dir>/.stderr, so there are no output/error options.
knit_with_flag "wait" "Block until the job completes; return its exit code."
# Record every submission as a row in the "jobs" table. The row id is the job
# UUID (set in _knit_submit); these outputs track the job and its state.
knit_with_table "${_KNIT_JOBS_TABLE}"
knit_with_output "job:string" "" "Name of the submitted job (the token after --)."
knit_with_output "state:string" "submitted" "Lifecycle state of the submitted job (submitted, running, completed, or killed)."
knit_with_output "hostnames:string" "" \
    "Comma-separated deduplicated nodes the job ran on (recorded at start)."
knit_with_output "native-cmd:string" "" \
    "The resolved scheduler command that was issued to submit the job."

# ------------------------------------------------------------------------------
# @fn _knit_submit()
#
# Entry point for the `submit` CLI command. A submission is built and then
# dispatched: _knit_prepare_build validates the request, creates the job
# directory, records the jobs row, generates the batch script, and freezes the
# resolved backend and options into a .submit metadata file; _knit_submit_dispatch
# then issues the scheduler command. `submit` runs both back to back, so its
# behaviour is a build immediately followed by a release. `prepare` runs only the
# build (see prepare.sh).
#
# Usage:
# ```
# ./exp.sh submit [--setup <setup-name>] [--name <alias>] [sched-args...] \
#     -- job-name [args...]
# ```
# ------------------------------------------------------------------------------
_knit_submit() {
    # The output variable names must not clash with _knit_prepare_build's own
    # internal locals (uuid/jobdir/alias_link/job_name), or the nameref outputs
    # would be shadowed (see the nameref-shadow-collision convention).
    local out_uuid out_jobdir out_alias out_jobname
    _knit_prepare_build out_uuid out_jobdir out_alias out_jobname \
        "submitted" "$@"
    _knit_submit_dispatch "${out_uuid}" "${out_jobdir}" "${out_jobname}" \
        "${out_alias}"
    # Return the job UUID (the canonical, scheduler-independent identifier). The
    # implementation-dependent launcher id lives only in .job.id.
    printf '%s\n' "${out_uuid}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_prepare_build()
#
# Build a submission without dispatching it: the shared first phase of `submit`
# and `prepare`. It validates the request (job known, usability, setup type,
# argument check), creates the job directory <job-root>/<uuid> (and any --name
# alias), records the jobs row in the target lifecycle state with an empty
# native-cmd, emits the setup "used_by" provenance edge, resolves the scheduler
# options and backend, generates the batch script .job.sh, and freezes the
# resolved backend and options into a .submit metadata file so a later release
# (_knit_submit_dispatch) is deterministic and needs no re-resolution.
#
# The four output arguments receive the job UUID, its directory, the --name
# alias symlink path (empty when no --name), and the job name. Callers MUST pass
# output variables whose names do not clash with this function's internal locals
# (uuid/jobdir/alias_link/job_name) — see the nameref-shadow-collision rule.
#
# Output namerefs come first, then the target state, then the submit CLI args.
#
# @param[out] __knit_ret1  Out: the job UUID (the jobs row id).
# @param[out] __knit_ret2  Out: the job directory <job-root>/<uuid>.
# @param[out] __knit_ret3  Out: the --name alias symlink path (empty when none).
# @param[out] __knit_ret4  Out: the job name (the token after --).
# @param[in] target_state Lifecycle state to record ("submitted" or "prepared").
# @param[in] ...          The submit CLI arguments (everything, including -- job args).
# ------------------------------------------------------------------------------
_knit_prepare_build() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local -n __knit_ret3=$3
    local -n __knit_ret4=$4
    local target_state="$5"
    shift 5

    # --setup is optional and, when given, names a setup instance under the
    # experiment's setup root (resolved to <setup-root>/<name> via
    # _knit_setup_name_to_path). It is required only for jobs that declare a setup
    # type (see knit_with_setup), so a missing value is not an error here.
    local setup_name
    setup_name=$(knit_get_parameter "setup" "$@") || setup_name=""
    local setup_path=""
    if [[ -n "${setup_name}" ]]; then
        _knit_setup_name_to_path setup_path "${setup_name}"
    fi

    # --name is an optional, stable alias for this job instance. When given it is
    # validated as a single path component and later symlinked under the job root
    # (<job-root>/<name> -> <job-root>/<uuid>) and recorded in the jobs table.
    local job_alias
    job_alias=$(knit_get_parameter "name" "$@") || job_alias=""
    if [[ -n "${job_alias}" ]]; then
        _knit_validate_instance_name "${job_alias}"
    fi

    # Extract extra args (after --): the job name and its arguments.
    local args=("$@")
    local extra_index
    extra_index=$(knit_extra_index "${args[@]}")
    local extra=("${args[@]:extra_index}")

    if [[ ${#extra[@]} -eq 0 ]]; then
        knit_fatal "submit requires a job name (pass it after --)."
    fi

    # The job name as typed (kept for the "unknown" error) and its canonical
    # (underscore) form, which drives lookup, the subcommand name, the batch
    # script, and the recorded row. Hyphens and underscores are interchangeable;
    # the registered spelling is restored for display below.
    local job_name_typed="${extra[0]}"
    local job_name
    job_name=$(_knit_name_normalize "${job_name_typed}")
    local job_args=("${extra[@]:1}")

    # Check job name is registered
    if [[ ! -v _KNIT_JOBS["${job_name}"] ]]; then
        knit_fatal "Unknown job \"${job_name_typed}\"."
    fi

    # Enforce the job's setup requirement (knit_with_setup / knit_without_setup).
    # A job that declares a setup type must be given a --setup built by that type.
    # A job that declares neither directive adopts the builtin "default" setup
    # implicitly *when no --setup is given*, so it runs in a setup and inherits
    # the platform environment with no boilerplate. When such a job IS given an
    # explicit --setup, it declared no type constraint, so it accepts whatever was
    # handed to it (no type enforcement). knit_without_setup opts out and runs
    # with no setup. The markers are the generic per-command markers set by those
    # decorators.
    local mangled
    mangled="$(_knit_command_mangle "submit:${job_name}")"

    # Registered spelling of the job, for human-facing messages.
    local job_display_var="_KNIT_CMD_${mangled}_display"
    local job_display="${!job_display_var:-${job_name}}"

    # Usability pre-check (login side): fail fast before creating a job directory
    # or contacting the scheduler if the job declares knit_usable_if predicates
    # that do not hold. The compute-side re-entry catches this too, but only after
    # the job has been scheduled.
    local usable_reason=""
    if ! _knit_command_check_usable usable_reason "${mangled}"; then
        knit_fatal "Command \"submit:${job_display}\" cannot run: ${usable_reason}"
    fi

    local required_marker="_KNIT_CMD_${mangled}_setup"
    local no_setup_marker="_KNIT_CMD_${mangled}_no_setup"
    local required_setup="${!required_marker:-}"
    local opted_out="${!no_setup_marker:-}"

    if [[ -z "${required_setup}" && -z "${opted_out}" && -z "${setup_path}" ]]; then
        required_setup="default"
        setup_path="$(_knit_default_setup_path)"
    fi

    if [[ -n "${required_setup}" && -z "${setup_path}" ]]; then
        knit_fatal "Job \"${job_display}\" requires a --setup of type \"${required_setup}\"."
    fi

    # Resolve the setup path (if any) to an absolute path. The generated batch
    # script cd's into the job directory before re-entering the experiment, so
    # every path baked into it (KNIT_SETUP_PREFIX, KNIT_JOB_PREFIX, the cd
    # target, and the backend's .stdout/.stderr paths, all derived from these)
    # must be absolute to survive that cd.
    if [[ -n "${setup_path}" ]]; then
        setup_path="$(realpath -m "${setup_path}" 2>/dev/null \
            || printf '%s' "${setup_path}")"
    fi

    # When the job requires a setup type, check the setup directory was built by
    # that type (shared with non-job commands via _knit_setup_check_type).
    if [[ -n "${required_setup}" ]]; then
        _knit_setup_check_type "${setup_path}" "${required_setup}"
    fi

    # Validate args for the job subcommand (knit_fatal on bad args)
    local subcmd="${mangled}"
    _knit_check_command_arguments "${subcmd}" "${job_args[@]}"

    # Every job lands in one job root, <job-root>/<uuid>, regardless of which
    # setup (if any) it uses: the generated jobscript references the setup by
    # absolute path, so the job directory need not nest under it. The job root is
    # resolved from bootstrap metadata (__job_path__) against the experiment root.
    local job_root
    _knit_job_root job_root

    # When --name is given, its alias symlink <job-root>/<name> must be free:
    # collision is fatal (rather than repointing) because the name is persisted to
    # the database and must stay stable. Check before creating anything so a
    # collision leaves no partial job directory behind.
    local alias_link=""
    if [[ -n "${job_alias}" ]]; then
        alias_link="${job_root}/${job_alias}"
        if [[ -e "${alias_link}" || -L "${alias_link}" ]]; then
            knit_fatal "Job name \"${job_alias}\" already exists at \"${alias_link}\"."
        fi
    fi

    # Create the job directory with a time-ordered uuidv7 name.
    local uuid jobdir
    uuid=$(_knit_uuidv7)
    jobdir="${job_root}/${uuid}"
    mkdir -p "${jobdir}"

    # Create the alias symlink now that the job directory exists. A relative
    # target keeps the link valid if the job root is later moved as a whole.
    if [[ -n "${alias_link}" ]]; then
        ln -s "${uuid}" "${alias_link}"
    fi

    # Record this submission under the "submit" command identity, regardless of
    # which dispatcher (submit or prepare) invoked this build. The "jobs" table,
    # its schema, and every provenance node/edge for a job belong to "submit"
    # (its declared outputs and its --wait column define the schema); recording a
    # prepared job under the "prepare" frame instead would need a second owner of
    # the same table and would label the row/edges "prepare", breaking the
    # name<->table map a graph query relies on. So resolve the owning command once
    # and record against it: a prepared job and a directly-submitted job then
    # produce identically-shaped, identically-labeled rows and edges.
    local owner
    owner="$(_knit_command_mangle "submit")"

    # The recorded row's id is the canonical job UUID. Set it on the executing
    # frame so the recording below (and any nested callee) sees it as the row id.
    _knit_set_row_id "${uuid}"

    # The two tracked outputs. knit_output would target the executing frame,
    # which for `prepare` is not `submit`, so write them straight to submit's
    # output map (both values are trivially valid for their declared string
    # type). The --name alias and the other submission parameters are recorded
    # automatically from the CLI args as their own columns. The state is the
    # caller-chosen target state ("submitted" for a direct submit, "prepared" for
    # `prepare`); native-cmd is left at its declared default (empty) and filled by
    # _knit_submit_dispatch on release.
    local -n _owner_outputs="_KNIT_CMD_${owner}_output_value"
    _owner_outputs["job"]="${job_name}"
    _owner_outputs["state"]="${target_state}"

    # Record a "used_by" edge from the setup this job references (if any) to this
    # submission, so the setup can be reached from the job by id. Emitted here on
    # the login side, where the setup was resolved and validated; the job's row id
    # is this submission's UUID. Best-effort and gated like other provenance
    # writes (see _knit_setup_record_used_by_edge).
    #
    # The edge target must be named after the command that owns the submission's
    # table (the "submit" dispatcher, whose table is "jobs"), NOT the job
    # subcommand and NOT the invoking dispatcher: the row lives in "jobs", and a
    # graph query resolves the node label through the name<->table map, so any
    # other name would point the edge at a table that command does not own and
    # make the used_by hop unmatchable.
    if [[ -n "${setup_path}" ]]; then
        _knit_setup_record_used_by_edge "${setup_path}" "${owner}" "${uuid}"
    fi

    # Resolve the submission options (explicit args -> metadata -> profile ->
    # hard-coded) into an associative array. Note: the name "opts" must differ
    # from the nameref names used inside the sched_* helpers to avoid bash
    # circular-reference errors.
    # shellcheck disable=SC2034 # populated and read by name via the sched_* helpers
    declare -A opts
    _knit_sched_resolve opts "$@"

    # Pick the scheduler backend: bootstrap metadata, else live detection, with
    # "none" mapping to the local (no-scheduler) backend.
    local backend
    _knit_sched_backend backend

    # When the walltime was defaulted (no --walltime, no project default), warn so
    # the user knows a limit was chosen for them and can set it explicitly. Only
    # for batch schedulers where walltime is a hard, queue-checked limit: for the
    # local/none backends it is just a soft kill convenience, so a default there
    # is unremarkable.
    if [[ "${opts["walltime-defaulted"]}" == "true" \
          && ( "${backend}" == "slurm" || "${backend}" == "pbs" ) ]]; then
        knit_warning "No --walltime given; defaulting to \"%s\" for queue \"%s\". Pass --walltime HH:MM:SS to set it explicitly." \
            "${opts["walltime"]}" "${opts["queue"]}"
    fi

    # Generate the batch script. The generated script exports
    # KNIT_JOB_PREFIX/KNIT_SETUP_PREFIX, cd's into the job directory, then calls
    # `path/to/exp.sh submit <job-name> [args...]` on the compute node.
    #
    # Note: `knit submit ... -- <job-name>` calls _knit_submit, while
    # `knit submit <job-name> [args]` is an actual invocation of the job's
    # registered function.
    local script="${jobdir}/.job.sh"
    # The submission's resolved row id is the job UUID (== jobs.id), and the
    # command name is the literal `submit`: the compute-side job body reads these
    # as its source context to record the call edge back to this submission.
    _knit_sched_write_jobscript "${script}" "${backend}" opts \
        "${setup_path}" "${jobdir}" "${uuid}" "submit" \
        "${job_name}" "${job_args[@]}"

    # Freeze the resolved backend and options next to the script so a later
    # release reconstructs the exact submission without re-resolving (values may
    # change between build and release).
    _knit_submit_meta_write "${jobdir}/.submit" "${backend}" opts

    # Persist the jobs row now, under the "submit" identity. For a direct submit
    # this must precede a blocking --wait dispatch: the job then runs (on this
    # host for the local backend, or on a compute node) and transitions this
    # row's "state" while it executes, so the row has to exist first.
    #
    # Clear submit's per-invocation "recorded" guard first so each build records
    # its own row: a single `prepare from` process builds many jobs in one run,
    # and (unlike a real `submit` invocation) nothing resets that guard between
    # them. For a direct submit `owner` is the executing command, so this matches
    # the old eager _knit_record_row_now: the automatic post-invocation recording
    # then finds the guard set and does not duplicate the row. For `prepare` the
    # invoking dispatcher declares no table and no provenance, so its own
    # post-invocation recording is a no-op.
    unset "_KNIT_CMD_${owner}_recorded"
    _knit_record_invocation "${owner}" "$@"

    __knit_ret1="${uuid}"
    __knit_ret2="${jobdir}"
    __knit_ret3="${alias_link}"
    __knit_ret4="${job_name}"
}

# ------------------------------------------------------------------------------
# @fn _knit_submit_dispatch()
#
# Release a built submission to the scheduler: the second phase of `submit`, and
# the whole of `submit prepared` / `submit next`. It reads the resolved backend
# and options from the job directory's .submit metadata (frozen by
# _knit_prepare_build), builds the scheduler submission command, records it as
# the row's native-cmd, advances the row to "submitted", issues the command, and
# handles a scheduler rejection (removing the never-run job, exactly as a direct
# submit does). On success it records the backend job id in .job.id.
#
# @param[in] uuid          The job UUID (the jobs row id).
# @param[in] jobdir        The job directory holding .submit and .job.sh.
# @param[in] job_name      The job name (for log and error messages).
# @param[in] alias_link    The --name alias symlink path, or empty when none (removed
#                      on rejection).
# @param[in] wait_override Optional: "true"/"false" to override the frozen "wait"
#                      option at release time (empty keeps the value frozen at
#                      build time). `submit` freezes --wait into .submit, so it
#                      passes nothing; `submit prepared`/`submit next` accept
#                      --wait at release and pass it here (prepared jobs freeze
#                      "wait" as false, since `prepare` has no --wait).
# ------------------------------------------------------------------------------
_knit_submit_dispatch() {
    local uuid="$1"
    local jobdir="$2"
    local job_name="$3"
    local alias_link="$4"
    local wait_override="${5:-}"

    # Registered spelling of the job (job_name is the canonical, underscore form),
    # for the log line below.
    local job_mangled
    job_mangled=$(_knit_command_mangle "submit:${job_name}")
    local job_display_var="_KNIT_CMD_${job_mangled}_display"
    local job_display="${!job_display_var:-${job_name}}"

    # Restore the backend and resolved options frozen at build time. The name
    # "opts" must differ from the nameref names used inside the sched_* helpers to
    # avoid bash circular-reference errors.
    local backend
    # shellcheck disable=SC2034 # populated by name, read by the sched_* helpers
    declare -A opts
    _knit_submit_meta_read "${jobdir}/.submit" backend opts

    # A release may re-decide whether to block: the batch script is unchanged, so
    # this only affects the submit-time wait behaviour, not the frozen spec.
    if [[ -n "${wait_override}" ]]; then
        opts["wait"]="${wait_override}"
    fi

    local script="${jobdir}/.job.sh"

    # Build the scheduler submission command (e.g. "sbatch <script>") so it can be
    # recorded in the jobs table and logged before it is issued.
    # shellcheck disable=SC2034 # filled and read by name via the sched_* helpers
    local -a submit_argv=()
    _knit_sched_submit_cmdline "${backend}" opts "${script}" submit_argv
    local native_cmd
    native_cmd=$(_knit_str_render_cmd submit_argv)

    # Record native-cmd and advance the row to "submitted" before dispatching: a
    # blocking --wait job transitions this same row's state as it runs, so the
    # recorded command and state must be in place first.
    _knit_db_update_row "${_KNIT_JOBS_TABLE}" "${uuid}" \
        "native-cmd=${native_cmd}" "state=submitted"

    # Log the resolved command before issuing it, then submit.
    knit_trace "Submitting job \"${job_display}\": ${native_cmd}"
    local jobid submit_status=0
    jobid="$(_knit_sched_submit "${backend}" opts "${script}" "${jobdir}")" \
        || submit_status=$?
    if (( submit_status != 0 )); then
        # The submission command exited non-zero. If the row is still "submitted"
        # the scheduler rejected the request (queue/resource limits, bad account,
        # ...) and the job never ran: it never became a job, so leave no trace of
        # it — delete the eagerly-recorded row and its provenance edge, remove the
        # job directory (and any --name alias), and abort. (A blocking --wait job
        # that was accepted but exited non-zero has already been moved to a
        # terminal state by the compute side; that state is left untouched,
        # preserving the existing behaviour for that case.)
        local cur_state uuid_esc
        _knit_sql_escape uuid_esc "${uuid}"
        cur_state="$(_knit_sqlite3 \
            "SELECT state FROM ${_KNIT_JOBS_TABLE} WHERE id='${uuid_esc}';" \
            2>/dev/null)" || cur_state=""
        if [[ -z "${cur_state}" || "${cur_state}" == "submitted" ]]; then
            _knit_submit_cleanup_rejected "${uuid}" "${jobdir}" "${alias_link}"
            knit_fatal "Job submission failed for \"%s\": the scheduler rejected the request (%s). The job was not recorded." \
                "${job_name}" "${native_cmd}"
        fi
    fi

    # Record the implementation-dependent launcher id in .job.id. The full
    # submission record lives in the "jobs" table (see M10/M11 recording).
    printf '%s\n' "${jobid}" > "${jobdir}/.job.id"
}

# ------------------------------------------------------------------------------
# @fn _knit_submit_meta_write()
#
# Freeze the resolved scheduler backend and options of a built submission into
# its .submit metadata file, so a later release reconstructs them without
# re-resolving. The format is one "key=value" per line: a single "backend=<name>"
# line, then one "opt:<key>=<value>" line per resolved option. A value is the
# rest of its line, so it may contain "=" or spaces but not a newline (no
# scheduler option does).
#
# @param[in] file     Path of the .submit file to write.
# @param[in] backend  Scheduler backend name.
# @param[in] arr_name Name of the resolved-options associative array to persist.
# ------------------------------------------------------------------------------
_knit_submit_meta_write() {
    local file="$1"
    local backend="$2"
    local -n _meta_opts="$3"
    {
        printf 'backend=%s\n' "${backend}"
        local key
        for key in "${!_meta_opts[@]}"; do
            printf 'opt:%s=%s\n' "${key}" "${_meta_opts[${key}]}"
        done
    } > "${file}"
}

# ------------------------------------------------------------------------------
# @fn _knit_submit_meta_read()
#
# Restore the scheduler backend and resolved options a submission was built with
# from its .submit metadata file (see _knit_submit_meta_write). The backend name
# is written to the first named variable; each recorded option is written into
# the named associative array, which the caller declares.
#
# @param[in] file        Path of the .submit file to read.
# @param[out] out_backend Name of the variable to receive the backend name.
# @param[out] arr_name    Name of the associative array to populate with the options.
# ------------------------------------------------------------------------------
_knit_submit_meta_read() {
    local file="$1"
    local -n _meta_backend="$2"
    local -n _meta_opts="$3"
    local line key
    while IFS= read -r line || [[ -n "${line}" ]]; do
        key="${line%%=*}"
        case "${key}" in
            backend) _meta_backend="${line#*=}" ;;
            opt:*)   _meta_opts["${key#opt:}"]="${line#*=}" ;;
        esac
    done < "${file}"
}

# ------------------------------------------------------------------------------
# @fn _knit_submit_cleanup_rejected()
#
# Undo the eager bookkeeping of a submission the scheduler rejected, so a job
# that never ran leaves no trace. knit submit records the jobs row (and, for a
# job with a setup, a "used_by" provenance edge) and creates the job directory
# before dispatching, because a blocking --wait job needs the row to exist so the
# compute side can transition it. When the submission command itself fails, none
# of that should survive: this removes the jobs row, any provenance edge pointing
# at it, the --name alias symlink (if any), and the job directory. Each step is
# best-effort (the provenance table may not exist for a setup-less job).
#
# @param[in] uuid       The submission's job UUID (its row id and edge target_id).
# @param[in] jobdir     The job directory to remove.
# @param[in] alias_link Path to the --name alias symlink, or empty when none.
# ------------------------------------------------------------------------------
_knit_submit_cleanup_rejected() {
    local uuid="$1"
    local jobdir="$2"
    local alias_link="$3"

    local uuid_esc jobs_ident id_ident
    _knit_sql_escape uuid_esc "${uuid}"
    _knit_db_sql_ident jobs_ident "${_KNIT_JOBS_TABLE}"
    _knit_db_sql_ident id_ident "id"
    _knit_sqlite3_write \
        "DELETE FROM ${jobs_ident} WHERE ${id_ident}='${uuid_esc}';" \
        2>/dev/null || true
    # Remove any provenance edge (e.g. a setup's "used_by") pointing at this
    # never-run submission. The table is absent for a setup-less job, hence the
    # tolerated failure.
    _knit_sqlite3_write \
        "DELETE FROM ${_KNIT_PROV_TABLE} WHERE target_id='${uuid_esc}';" \
        2>/dev/null || true

    [[ -n "${alias_link}" && -L "${alias_link}" ]] && rm -f "${alias_link}"
    rm -rf "${jobdir}"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_set_state()
#
# Update the lifecycle state of the running job's jobs-table row. Called on the
# compute side, where the experiment's .knit is shared over the parallel file
# system, so the row inserted by knit submit on the login node can be updated in
# place. The row id is the job UUID, i.e. the basename of KNIT_JOB_PREFIX (the
# job directory). Best-effort: status tracking must never take down the job
# itself, so a failure is downgraded to a warning.
#
# @param[in] state New state value (e.g. running, completed, killed).
# ------------------------------------------------------------------------------
_knit_job_set_state() {
    local state="$1"
    [[ -v KNIT_JOB_PREFIX ]] || return 0
    _knit_is_bootstrapped || return 0
    local uuid
    uuid="$(basename "${KNIT_JOB_PREFIX}")"
    _knit_db_update_row "${_KNIT_JOBS_TABLE}" "${uuid}" "state=${state}" \
        2>/dev/null \
        || knit_warning "Could not update job \"${uuid}\" state to \"${state}\"."
}

# ------------------------------------------------------------------------------
# @fn _knit_job_record_hostnames()
#
# Record the nodes the running job was allocated into its jobs-table row. Called
# on the compute side, once the job is running, where the scheduler has populated
# the node allocation and the experiment's .knit is shared over the parallel file
# system (so the row inserted by knit submit on the login node can be updated in
# place). The stored value is the deduplicated, comma-separated host list, i.e.
# the output of `knit_job_hostnames --separator ,`. The row id is the job UUID,
# i.e. the basename of KNIT_JOB_PREFIX. Best-effort: like state tracking, a
# failure is downgraded to a warning so it never takes down the job.
# ------------------------------------------------------------------------------
_knit_job_record_hostnames() {
    [[ -v KNIT_JOB_PREFIX ]] || return 0
    _knit_is_bootstrapped || return 0
    local uuid hosts
    uuid="$(basename "${KNIT_JOB_PREFIX}")"
    # Command substitution strips the trailing newline, leaving a bare
    # comma-separated list (empty if host discovery finds nothing).
    hosts="$(knit_job_hostnames --separator ,)"
    _knit_db_update_row "${_KNIT_JOBS_TABLE}" "${uuid}" "hostnames=${hosts}" \
        2>/dev/null \
        || knit_warning "Could not record hostnames for job \"${uuid}\"."
}

# ------------------------------------------------------------------------------
# @fn _knit_job_killed_trap()
#
# Signal handler installed while a job runs on the compute node. Schedulers warn
# a job before killing it: Slurm can send a chosen signal a configurable time
# before the walltime limit (requested via --signal in the batch directives) and
# sends SIGTERM before SIGKILL; PBS likewise sends SIGTERM before SIGKILL. Flux
# cancels a batch job by shutting down its instance, which sends SIGHUP to the
# batch initial program. This handler records the job as "killed" so its row does
# not stay stuck at "running", then exits so the after-callback (which would mark
# it "completed") does not run.
# ------------------------------------------------------------------------------
_knit_job_killed_trap() {
    _knit_job_set_state "killed"
    exit 143
}

# ------------------------------------------------------------------------------
# @fn _knit_job_before_cb()
#
# Before-callback installed on every setup subcommand by knit_register_job.
# Verifies that KNIT_JOB_PREFIX is set, ensuring the job was invoked through
# `knit submit` rather than called directly, installs the pre-termination signal
# handler, marks the job "running", records the allocated hostnames, and sources
# the setup environment when the job uses one.
# ------------------------------------------------------------------------------
_knit_job_before_cb() {
    if [[ ! -v KNIT_JOB_PREFIX ]]; then
        knit_fatal "Job commands must be invoked via \"knit submit [OPTIONS] -- <job> [OPTIONS]\", not directly."
    fi
    # Catch the scheduler's pre-termination signal so an out-of-time or cancelled
    # job records "killed" before it is hard-killed (see _knit_job_killed_trap).
    # HUP covers Flux, which sends it to the batch program when it cancels a job.
    trap '_knit_job_killed_trap' HUP TERM USR1
    _knit_job_set_state "running"
    _knit_job_record_hostnames
    # Setup-less jobs (no knit_with_setup) run without a KNIT_SETUP_PREFIX, so
    # there is no environment to source.
    if [[ -n "${KNIT_SETUP_PREFIX:-}" ]]; then
        # shellcheck disable=SC1091
        source "${KNIT_SETUP_PREFIX}/.activate.sh"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_job_after_cb()
#
# After-callback installed on every submit subcommand by knit_register_job.
# Marks the job "completed" once its body has returned normally.
# ------------------------------------------------------------------------------
_knit_job_after_cb() {
    _knit_job_set_state "completed"
}

# ------------------------------------------------------------------------------
# @fn knit_job_hostnames()
#
# Print the hostnames the current job is running on, discovered from the active
# scheduler backend (see _knit_sched_hostfile). Intended to be called inside a
# job body. Outside a scheduler allocation it reports the local hostname.
#
# By default each host is printed once, on its own line, with any trailing ":N"
# slot-count or extra columns removed and duplicates collapsed (first-seen order
# preserved). Use --raw to print the backend's hostfile entries verbatim (e.g.
# one line per launchable slot), which is the form an MPI launcher hostfile wants.
#
# Usage: `knit_job_hostnames [--json] [--separator <sep>] [--raw] [--select <s>:<n>]`
#
# @param[in] --json      Print the hostnames as a JSON array of strings.
# @param[in] --separator Separator used to join hostnames (default: a newline).
#                    Ignored when --json is given.
# @param[in] --raw       Print the raw hostfile entries verbatim (no ":N" stripping,
#                    no deduplication); only the separator / JSON wrapping is
#                    applied.
# @param[in] --select    Print only a slice of the resulting list: <start>:<length>,
#                    where <start> is a 0-based index and <length> is the number
#                    of hostnames to print. The slice is taken after the raw or
#                    deduplication step, so it counts the entries that would
#                    otherwise be printed. Out-of-range requests are clamped (a
#                    start past the end yields nothing).
# ------------------------------------------------------------------------------
knit_job_hostnames() {
    local as_json=0 raw=0 sep=$'\n' have_sep=0 sel=""
    while (( $# )); do
        case "$1" in
            --json)         as_json=1; shift ;;
            --raw)          raw=1; shift ;;
            --separator)    sep="$2"; have_sep=1; shift 2 ;;
            --separator=*)  sep="${1#*=}"; have_sep=1; shift ;;
            --select)       sel="$2"; shift 2 ;;
            --select=*)     sel="${1#*=}"; shift ;;
            --)             shift ;;
            *) knit_error "knit_job_hostnames: unknown argument \"%s\"." "$1"
               return 1 ;;
        esac
    done
    if (( as_json && have_sep )); then
        knit_warning "knit_job_hostnames: --separator is ignored with --json."
    fi
    if [[ -n "${sel}" && ! "${sel}" =~ ^[0-9]+:[0-9]+$ ]]; then
        knit_error "knit_job_hostnames: --select must be <start_index>:<length>, got \"%s\"." "${sel}"
        return 1
    fi

    local -a lines=()
    mapfile -t lines < <(_knit_sched_hostfile)

    local -a hosts=()
    if (( raw )); then
        hosts=("${lines[@]}")
    else
        # Strip a trailing ":N" or extra whitespace-separated columns, drop blank
        # lines, and keep each hostname once in first-seen order.
        local -A seen=()
        local line h
        for line in "${lines[@]}"; do
            h="${line%%:*}"
            h="${h%%[[:space:]]*}"
            [[ -z "${h}" ]] && continue
            [[ -n "${seen[${h}]:-}" ]] && continue
            seen[${h}]=1
            hosts+=("${h}")
        done
    fi

    if [[ -n "${sel}" ]]; then
        # Keep only <length> entries starting at the 0-based <start_index>; bash
        # slicing clamps a length that runs past the end and yields nothing for a
        # start past the end.
        hosts=("${hosts[@]:${sel%%:*}:${sel#*:}}")
    fi

    if (( as_json )); then
        # shellcheck disable=SC2016 # $ARGS is jq syntax, not a shell variable.
        _knit_jq -nc '$ARGS.positional' --args "${hosts[@]}"
    else
        (( ${#hosts[@]} == 0 )) && return 0
        local out="${hosts[0]}" i
        for (( i = 1; i < ${#hosts[@]}; i++ )); do
            out+="${sep}${hosts[i]}"
        done
        printf '%s\n' "${out}"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_job_nodecount()
#
# Print the number of distinct nodes allocated to the current job: the count of
# deduplicated hostnames reported by knit_job_hostnames (so a host contributing
# several launchable slots is counted once). Intended to be called inside a job
# body; outside a scheduler allocation it reports 1 (the local host). A common use
# is to launch one rank per node: `knit run --procs "$(knit_job_nodecount)"
# --procs-per-node 1 -- <app>`.
#
# Takes no arguments.
# ------------------------------------------------------------------------------
knit_job_nodecount() {
    if (( $# )); then
        knit_error "knit_job_nodecount: unexpected argument \"%s\"." "$1"
        return 1
    fi
    local -a hosts=()
    mapfile -t hosts < <(knit_job_hostnames)
    printf '%s\n' "${#hosts[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_command_is_job()
#
# Test whether a command is a job, i.e. it was registered with knit_register_job.
# A job's row carries a "state" column written from its callbacks and signal
# traps (running / killed / completed), so a directive that would suppress that
# row can consult this to reject a job. Reads the command kind from the
# _KNIT_CMD_<cmd>_type field (see knit_register).
#
# @param[in] cmd Command (mangled name) to test.
# @return 0 if the command is a job, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_command_is_job() {
    local var="_KNIT_CMD_${1}_type"
    [[ "${!var:-}" == "job" ]]
}

# ------------------------------------------------------------------------------
# @fn knit_register_job()
#
# Register a job, i.e. a subcommand of the "submit" command that executes as a
# job sumitted on the supercomputer.
#
# A call to this function must be followed by any knit_with_* declarations,
# the definition of <fn>, and a call to knit_done.
#
# The names "prepared", "next", and "from" are reserved: "submit prepared" and
# "submit next" release prepared jobs and "prepare from" reads a plan, so a job
# registered under one of these would mangle to the same command name and shadow
# the release/plan subcommand. Registering such a job is fatal.
#
# @param[in] name        Short name for the job (used as the subcommand name).
# @param[in] fn          Name of the Bash function implementing the job.
# @param[in] description One-line description shown in `--help`.
#
# Example:
# ```
# knit_register_job "hello" "hello_fn" "Hello world job script."
# knit_with_optional "name:string" "Matthieu" "Name of the person to greet."
# hello_fn() {
#   ...
# }
# knit_done
# ```
# ------------------------------------------------------------------------------
knit_register_job() {
    local name="$1"
    local fn="$2"
    local description="$3"
    case "${name}" in
        prepared|next|from)
            knit_fatal "Job name \"${name}\" is reserved (it would shadow a \"submit\"/\"prepare\" subcommand)."
            ;;
    esac
    knit_register "submit:${name}" "${fn}" "${description}"
    # Canonical (underscore) name: used both for the per-job table and the
    # registry key so they stay stable whether the job is registered or invoked
    # with hyphens or underscores (the registered spelling is kept for display).
    local normalized_name
    normalized_name=$(_knit_name_normalize "${name}")
    # Record each job's invocations in a table named after the job itself (not
    # the "submit:<name>" command name), so the table reads naturally and needs
    # no SQL quoting of the colon.
    knit_with_table "${normalized_name}"
    _KNIT_JOBS["${normalized_name}"]=1
    printf -v "_KNIT_CMD_${_KNIT_CURRENT_COMMAND}_type" '%s' 'job'
    _knit_run_before _knit_job_before_cb
    _knit_run_after  _knit_job_after_cb
}
