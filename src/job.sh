#!/bin/bash

## @file job.sh

# ------------------------------------------------------------------------------
# @var _KNIT_JOBS
#
# Associative array mapping registered job names to 1. Used to validate that
# a job names passed to `knit submit` is known.
# ------------------------------------------------------------------------------
declare -A _KNIT_JOBS

# ------------------------------------------------------------------------------
# Name of the table recording every job and its lifecycle state. The row id is
# the job UUID; the "state" column moves submitted -> running -> completed, or
# -> killed when the scheduler terminates a job before it finishes.
# ------------------------------------------------------------------------------
_KNIT_JOBS_TABLE="jobs"

knit_register _knit_submit "submit" "Submit a job."
_knit_is_builtin
knit_with_optional "setup:string" "" \
    "Name of the setup to use (required if the job declares a setup type)."
# A stable, human-meaningful alias for this job instance under the job root:
# `knit submit --name <name>` creates a symlink <job-root>/<name> -> <job-root>/
# <uuid> and records the name in the jobs table. Distinct from --job-name below,
# which is the scheduler-facing job name (#SBATCH --job-name / #PBS -N).
knit_with_optional "name:string" "" \
    "Stable alias for this job (symlinked under the job root; must be unique)."
# Identity. Empty defaults are the "not set" sentinel: _knit_sched_resolve fills
# them from bootstrap metadata, the machine profile, or a hard-coded fallback.
knit_with_optional "job-name:string" "" \
    "Job name (default: the experiment script name)."
knit_with_optional "account:string" "" \
    "Account (default: the __account__ metadata)."
knit_with_optional "project:string" "" \
    "Project name (default: the __project__ metadata)."
knit_with_optional "queue:string" "" \
    "Queue/partition (default: the site default queue)."
# Resources. Knit allocates whole nodes exclusively: the per-node core count is
# taken from the machine profile (or bootstrap detection), not requested per
# submit, so there is no CPU option here.
knit_with_optional "nodes:integer" "1" "Number of nodes."
knit_with_optional "walltime:string" "" \
    "Wall-clock limit as HH:MM:SS (default: the site default)."
knit_with_optional "gpus-per-node:integer" "0" "GPUs per node."
# Behaviour. Job stdout/stderr are always written to <job-dir>/.stdout and
# <job-dir>/.stderr, so there are no output/error options.
knit_with_flag "wait" "Block until the job completes; return its exit code."
knit_with_dispatch "job" "User-provided job command to execute"
knit_with_subcommand_title "Jobs"
# Record every submission as a row in the "jobs" table. The row id is the job
# UUID (set in _knit_submit); these outputs track the job and its state.
knit_with_table "${_KNIT_JOBS_TABLE}"
knit_with_output "job:string" "" "Name of the submitted job (the token after --)."
knit_with_output "state:string" "submitted" "Lifecycle state of the submitted job."
knit_with_output "hostnames:string" "" \
    "Comma-separated deduplicated nodes the job ran on (recorded at start)."
knit_with_output "native-cmd:string" "" \
    "The resolved scheduler command that was issued to submit the job."

# ------------------------------------------------------------------------------
# @fn _knit_submit()
#
# Entry point for the `submit` CLI command.
#
# Usage:
# ```
# ./exp.sh submit [--setup <setup-name>] [--name <alias>] [sched-args...] \
#     -- job-name [args...]
# ```
# ------------------------------------------------------------------------------
_knit_submit() {
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

    local job_name="${extra[0]}"
    local job_args=("${extra[@]:1}")

    # Check job name is registered
    if [[ ! -v _KNIT_JOBS["${job_name}"] ]]; then
        knit_fatal "Unknown job \"${job_name}\"."
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
    local required_marker="_KNIT_CMD_${mangled}_setup"
    local no_setup_marker="_KNIT_CMD_${mangled}_no_setup"
    local required_setup="${!required_marker:-}"
    local opted_out="${!no_setup_marker:-}"

    if [[ -z "${required_setup}" && -z "${opted_out}" && -z "${setup_path}" ]]; then
        required_setup="default"
        setup_path="$(_knit_default_setup_path)"
    fi

    if [[ -n "${required_setup}" && -z "${setup_path}" ]]; then
        knit_fatal "Job \"${job_name}\" requires a --setup of type \"${required_setup}\"."
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

    # Record this submission: the recorded row's id is the canonical job
    # UUID, and the jobs table tracks the job name and lifecycle state. The
    # --name alias is recorded automatically as its own "name" column, like the
    # other submit parameters.
    _knit_set_row_id "${uuid}"
    knit_output "job" "${job_name}"
    knit_output "state" "submitted"

    # Record a "used_by" edge from the setup this job references (if any) to this
    # submission, so the setup can be reached from the job by id. Emitted here on
    # the login side, where the setup was resolved and validated; the job's row id
    # is this submission's UUID. Best-effort and gated like other provenance
    # writes (see _knit_setup_record_uses_edge).
    if [[ -n "${setup_path}" ]]; then
        _knit_setup_record_uses_edge "${setup_path}" "${subcmd}" "${uuid}"
    fi

    # Resolve the submission options (explicit args -> metadata -> profile ->
    # hard-coded) into an associative array. Note: the name "opts" must differ
    # from the nameref names used inside the sched_* helpers to avoid bash
    # circular-reference errors.
    # shellcheck disable=SC2034 # populated and read by name via the sched_* helpers
    declare -A opts
    _knit_sched_resolve opts "$@"

    # Fail fast if the request exceeds the target queue's profile caps, before
    # writing a script or contacting the scheduler.
    _knit_sched_validate_caps opts

    # Pick the scheduler backend: bootstrap metadata, else live detection, with
    # "none" mapping to the local (no-scheduler) backend.
    local backend
    _knit_sched_backend backend

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

    # Build the scheduler submission command (e.g. "sbatch <script>") so it can be
    # recorded in the jobs table and logged before it is issued.
    # shellcheck disable=SC2034 # filled and read by name via the sched_* helpers
    local -a submit_argv=()
    _knit_sched_submit_cmdline "${backend}" opts "${script}" submit_argv
    local native_cmd
    native_cmd=$(_knit_str_render_cmd submit_argv)
    knit_output "native-cmd" "${native_cmd}"

    # Persist the jobs row now, before dispatching. This must precede a
    # blocking --wait submission: the job then runs (on this host for the local
    # backend, or on a compute node) and transitions this row's "state" while it
    # executes, so the row has to exist first. The automatic post-invocation
    # recording is idempotent and will not duplicate it.
    _knit_record_row_now "$@"

    # Log the resolved command before issuing it, then submit.
    knit_trace "Submitting job \"${job_name}\": ${native_cmd}"
    local jobid
    jobid="$(_knit_sched_submit "${backend}" opts "${script}" "${jobdir}")"

    # Record the implementation-dependent launcher id in .job.id. The full
    # submission record lives in the "jobs" table (see M10/M11 recording).
    printf '%s\n' "${jobid}" > "${jobdir}/.job.id"

    # Return the job UUID (the canonical, scheduler-independent identifier). The
    # implementation-dependent launcher id lives only in .job.id.
    printf '%s\n' "${uuid}"
}
knit_done

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
# @param state New state value (e.g. running, completed, killed).
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
# sends SIGTERM before SIGKILL; PBS likewise sends SIGTERM before SIGKILL. This
# handler records the job as "killed" so its row does not stay stuck at
# "running", then exits so the after-callback (which would mark it "completed")
# does not run.
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
    trap '_knit_job_killed_trap' TERM USR1
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
# @param --json      Print the hostnames as a JSON array of strings.
# @param --separator Separator used to join hostnames (default: a newline).
#                    Ignored when --json is given.
# @param --raw       Print the raw hostfile entries verbatim (no ":N" stripping,
#                    no deduplication); only the separator / JSON wrapping is
#                    applied.
# @param --select    Print only a slice of the resulting list: <start>:<length>,
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
# @fn knit_register_job()
#
# Register a job, i.e. a subcommand of the "submit" command that executes as a
# job sumitted on the supercomputer.
#
# A call to this function must be followed by any knit_with_* declarations,
# the definition of <fn>, and a call to knit_done.
#
# @param name        Short name for the job (used as the subcommand name).
# @param fn          Name of the Bash function implementing the job.
# @param description One-line description shown in `--help`.
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
    knit_register "${fn}" "submit:${name}" "${description}"
    # Record each job's invocations in a table named after the job itself (not
    # the "submit:<name>" command name), so the table reads naturally and needs
    # no SQL quoting of the colon.
    knit_with_table "${name}"
    _KNIT_JOBS["${name}"]=1
    _knit_run_before _knit_job_before_cb
    _knit_run_after  _knit_job_after_cb
}
