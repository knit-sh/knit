#!/bin/bash

## @file pilot.sh

# ------------------------------------------------------------------------------
# Version of knit-pilotd to provision.
# ------------------------------------------------------------------------------
_KNIT_PILOTD_VERSION="0.1.0"

# ------------------------------------------------------------------------------
# Path to the knit-pilotd executable.
# ------------------------------------------------------------------------------
_KNIT_PILOTD_EXE="${_KNIT_PREFIX}/knit-pilotd/bin/knit-pilotd"

# ------------------------------------------------------------------------------
# @fn _knit_pilotd_url()
#
# Print the download URL for a knit-pilotd release tarball given its version. The
# release tag is the version prefixed with "v" and the asset is named after the
# version, e.g. version 0.1.0 ->
# .../download/v0.1.0/knit-pilotd-0.1.0.tar.gz.
#
# @param[in] version knit-pilotd release version (without the leading "v").
# ------------------------------------------------------------------------------
_knit_pilotd_url() {
    local version="$1"
    printf 'https://github.com/knit-sh/knit-pilotd/releases/download/v%s/knit-pilotd-%s.tar.gz' \
        "${version}" "${version}"
}

# ------------------------------------------------------------------------------
# @fn _knit_build_pilotd()
#
# Download the knit-pilotd release tarball, build it, and install it under
# .knit/knit-pilotd. The daemon is a single dependency-free POSIX C file, so the
# build needs only a C compiler: the release tarball ships a hand-written
# configure script (no autotools), built out of tree with
# "../configure --prefix=... && make && make install".
#
# @param[in] version knit-pilotd release version to build.
# @param[in] url URL of the knit-pilotd release tarball.
# ------------------------------------------------------------------------------
_knit_build_pilotd() {
    local version="$1"
    local url="$2"
    local srcname="knit-pilotd-${version}"
    local tarball="${srcname}.tar.gz"

    knit_pushd "${_KNIT_PREFIX}"

    knit_trace "Downloading knit-pilotd source..."
    # -f makes an HTTP error status (e.g. a rate-limited GitHub response) a clean
    # failure instead of a saved error body that would later fail to extract;
    # --retry rides out a transient network error. A GITHUB_TOKEN/GH_TOKEN, when
    # set, lifts the low anonymous rate limit that CI runners share by address.
    local -a curl_args=(-fL --retry 3 --retry-delay 2 -o "${tarball}")
    local gh_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    [[ -n "${gh_token}" ]] && curl_args+=(-H "Authorization: Bearer ${gh_token}")
    if ! knit_framed_run "knit-pilotd: download" \
            curl "${curl_args[@]}" "${url}" ; then
        knit_fatal "Could not download knit-pilotd from ${url}. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Extracting knit-pilotd source..."
    if ! knit_framed_run "knit-pilotd: extract" \
            tar -xzf "${tarball}" ; then
        knit_fatal "Could not extract knit-pilotd sources. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Building knit-pilotd..."
    mkdir "${srcname}/build"
    knit_pushd "${srcname}/build"
    if ! knit_framed_run "knit-pilotd: configure" \
            ../configure --prefix="${_KNIT_PREFIX}/knit-pilotd" ; then
        knit_fatal "Could not configure knit-pilotd. See ${_KNIT_TRACE_FILE} for more information."
    fi
    if ! knit_framed_run "knit-pilotd: make" \
            make ; then
        knit_fatal "Could not build knit-pilotd. See ${_KNIT_TRACE_FILE} for more information."
    fi
    if ! knit_framed_run "knit-pilotd: make install" \
            make install ; then
        knit_fatal "Could not install knit-pilotd. See ${_KNIT_TRACE_FILE} for more information."
    fi
    knit_popd # from "${srcname}/build"

    knit_trace "Deleting knit-pilotd sources and archive..."
    rm -rf "${srcname}" "${tarball}" 2>"${_KNIT_TRACE_FILE}"

    knit_popd # from "${_KNIT_PREFIX}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_pilotd()
#
# Provision knit-pilotd at _KNIT_PILOTD_EXE. Resolves the version (the pinned
# default when empty) and the download URL (derived from the version when empty),
# builds and installs the daemon, and records provenance metadata (the version
# and URL provisioned). The daemon links no libraries, so this is independent of
# the other provisioning steps.
#
# @param[in] version knit-pilotd version to provision; empty uses the pinned default.
# @param[in] url Override URL for the release tarball; empty derives it from the version.
# ------------------------------------------------------------------------------
_knit_bootstrap_pilotd() {
    local version="${1:-}"
    local url="${2:-}"
    if [[ -z "${version}" ]]; then
        version="${_KNIT_PILOTD_VERSION}"
    fi
    if [[ -z "${url}" ]]; then
        url="$(_knit_pilotd_url "${version}")"
    fi

    _knit_build_pilotd "${version}" "${url}"

    knit_trace "Storing knit-pilotd provenance metadata..."
    knit metadata store --key "__knit_pilotd_version__" --value "${version}"
    knit metadata store --key "__knit_pilotd_url__"     --value "${url}"
}

# ------------------------------------------------------------------------------
# @var KNIT_PILOT
#
# Public environment variable exported into a pilot job body (and inherited by
# every command it runs) to signal that an in-allocation knit-pilotd daemon is
# active. Its presence lifts the nested-submit guard (see
# _knit_pilot_reject_nested_submit) and retargets `knit submit` to the pilot
# scheduler. A sub-job launched by the daemon has it unset, so a sub-job cannot
# itself act as a pilot (no nested pilots).
# ------------------------------------------------------------------------------
declare -gx KNIT_PILOT

# ------------------------------------------------------------------------------
# @var KNIT_PILOT_SOCK
#
# Public environment variable exported alongside KNIT_PILOT: the path of the
# knit-pilotd control socket the pilot job's body (and its `knit submit` calls)
# use to talk to the daemon.
# ------------------------------------------------------------------------------
declare -gx KNIT_PILOT_SOCK

# ------------------------------------------------------------------------------
# @var _KNIT_PILOT_DAEMON_PID
#
# PID of the knit-pilotd daemon the pilot before-callback started, kept so the
# after-callback can reap it. Lives only within the pilot job body's process.
# ------------------------------------------------------------------------------
declare -g _KNIT_PILOT_DAEMON_PID

# ------------------------------------------------------------------------------
# @fn _knit_pilot_reject_nested_submit()
#
# The nested-submit guard. `knit submit` is allowed on the login node and, inside
# a pilot job, retargeted to the in-allocation daemon; everywhere else inside a
# job body it is rejected. Returns 0 (allow) when not inside a job body
# (KNIT_JOB_PREFIX unset — the ordinary login-side submission) or when a pilot is
# active (KNIT_PILOT set); otherwise it is a nested submission from a non-pilot
# job body and fatals, naming knit_with_pilot. Called at the top of _knit_submit,
# which only the real `submit -- <job>` dispatch reaches — the compute-side body
# re-entry runs `submit <job>` (no --) straight into the job function, so this
# never blocks a job from starting.
# ------------------------------------------------------------------------------
_knit_pilot_reject_nested_submit() {
    [[ -v KNIT_JOB_PREFIX ]] || return 0
    [[ -n "${KNIT_PILOT:-}" ]] && return 0
    knit_fatal "\"knit submit\" cannot be called from inside a job body.\nTo run sub-jobs on the job's own allocation, declare the job a pilot with knit_with_pilot."
}

# ------------------------------------------------------------------------------
# @fn _knit_pilot_build_nodelist()
#
# Print the comma-separated node list for the pilot daemon's resource pool: the
# deduplicated hostnames the pilot job was allocated (knit_job_hostnames). When
# exclude_launch_host is non-empty, the daemon's own host is dropped from the
# pool if present — compared on the short (pre-dot) name so it matches whether
# the allocation reports short names or FQDNs. The drop is a no-op when the host
# is not in the pool (a separate launch/service node). Prints the empty string
# when no node remains.
#
# @param[in] exclude_launch_host Non-empty to drop the local host from the pool.
# ------------------------------------------------------------------------------
_knit_pilot_build_nodelist() {
    local exclude_launch_host="$1"
    local -a hosts=()
    mapfile -t hosts < <(knit_job_hostnames)
    if [[ -n "${exclude_launch_host}" ]]; then
        local self short
        self="$(hostname)"
        short="${self%%.*}"
        local -a kept=()
        local h
        for h in "${hosts[@]}"; do
            [[ "${h%%.*}" == "${short}" ]] && continue
            kept+=("${h}")
        done
        hosts=("${kept[@]}")
    fi
    local out="" h
    for h in "${hosts[@]}"; do
        out+="${out:+,}${h}"
    done
    printf '%s\n' "${out}"
}

# ------------------------------------------------------------------------------
# @fn _knit_pilot_before_cb()
#
# Before-callback installed by knit_with_pilot, run after the generic job
# before-callback (so the allocation's hostnames are already discoverable). It
# builds the resource inventory — the node pool (knit_job_hostnames, less the
# launch host when --exclude-launch-host) plus the per-node core/GPU counts from
# bootstrap metadata — starts knit-pilotd on a control socket under the job
# directory, waits for the socket to appear, and exports KNIT_PILOT /
# KNIT_PILOT_SOCK so the body's `knit submit` calls reach the daemon. The node
# pool is built before KNIT_PILOT is exported so host discovery still resolves
# the real scheduler backend. Daemon output goes to <jobdir>/pilot.log.
#
# @param[in] exclude_launch_host Non-empty to drop the local host from the pool.
# @param[in] ... The job's own runtime arguments (ignored).
# ------------------------------------------------------------------------------
_knit_pilot_before_cb() {
    local exclude_launch_host="$1"
    local sock="${KNIT_JOB_PREFIX}/pilot.sock"

    local nodes
    nodes="$(_knit_pilot_build_nodelist "${exclude_launch_host}")"
    if [[ -z "${nodes}" ]]; then
        knit_fatal "Pilot job has no nodes to schedule onto (empty allocation after --exclude-launch-host?)."
    fi

    local cores gpus
    _knit_metadata_get cores "__node_ncpus__"
    _knit_metadata_get gpus "__node_ngpus__"
    local -a daemon_args=(daemon --socket "${sock}" --nodes "${nodes}")
    [[ -n "${cores}" ]] && daemon_args+=(--cores-per-node "${cores}")
    [[ -n "${gpus}" ]] && daemon_args+=(--gpus-per-node "${gpus}")

    "${_KNIT_PILOTD_EXE}" "${daemon_args[@]}" \
        >> "${KNIT_JOB_PREFIX}/pilot.log" 2>&1 &
    _KNIT_PILOT_DAEMON_PID=$!

    # Wait (bounded) for the daemon to bind its control socket, bailing out early
    # if it dies before it does.
    local i
    for (( i = 0; i < 100; i++ )); do
        [[ -S "${sock}" ]] && break
        kill -0 "${_KNIT_PILOT_DAEMON_PID}" 2>/dev/null || break
        sleep 0.05
    done
    if [[ ! -S "${sock}" ]]; then
        knit_fatal "knit-pilotd did not create its control socket at \"${sock}\". See ${KNIT_JOB_PREFIX}/pilot.log for details."
    fi

    export KNIT_PILOT=1
    export KNIT_PILOT_SOCK="${sock}"

    # A kill of the pilot job must tear the daemon down too, so override the
    # generic job kill-trap (installed by _knit_job_before_cb, which ran first)
    # with the pilot-aware one: it kills every sub-job and reconciles their rows
    # before the pilot records itself killed.
    trap '_knit_pilot_killed_trap' HUP TERM USR1

    knit_trace "Started knit-pilotd (pid ${_KNIT_PILOT_DAEMON_PID}) over nodes: ${nodes}"
}

# ------------------------------------------------------------------------------
# @fn _knit_pilot_record_subjob()
#
# Record a sub-job UUID the pilot submitted, one per line, in a tracking file
# under the pilot job directory. Teardown reads this list to reconcile sub-jobs
# the daemon killed or dropped: a running sub-job records its own "killed" when
# signalled, but a still-queued sub-job never started a knit process and would
# otherwise stay "submitted", so the pilot marks it killed from this list. A
# no-op when not inside a pilot job directory (e.g. under unit tests).
#
# @param[in] id The sub-job UUID just queued with the daemon.
# ------------------------------------------------------------------------------
_knit_pilot_record_subjob() {
    local id="$1"
    [[ -n "${KNIT_JOB_PREFIX:-}" && -d "${KNIT_JOB_PREFIX}" ]] || return 0
    printf '%s\n' "${id}" >> "${KNIT_JOB_PREFIX}/.pilot.subjobs"
}

# ------------------------------------------------------------------------------
# @fn _knit_pilot_mark_outstanding_killed()
#
# Mark every sub-job the pilot submitted that is not already in a terminal state
# as "killed" in the jobs table. Called from the kill paths (a killed pilot, or
# --kill-on-exit) after the daemon has been told to kill/drop outstanding
# sub-jobs: it closes the gap for queued sub-jobs that never started a process of
# their own (and so never recorded a terminal state) and is a harmless idempotent
# re-write for running sub-jobs whose own kill-trap already recorded "killed".
# Best-effort and gated on bootstrap; a sub-job with no row (unknown state) is
# skipped. Reads the tracking file written by _knit_pilot_record_subjob.
# ------------------------------------------------------------------------------
_knit_pilot_mark_outstanding_killed() {
    _knit_is_bootstrapped || return 0
    local file="${KNIT_JOB_PREFIX:-}/.pilot.subjobs"
    [[ -r "${file}" ]] || return 0
    local id esc state
    while IFS= read -r id || [[ -n "${id}" ]]; do
        [[ -z "${id}" ]] && continue
        _knit_sql_escape esc "${id}"
        state="$(_knit_sqlite3 \
            "SELECT state FROM ${_KNIT_JOBS_TABLE} WHERE id='${esc}';" \
            2>/dev/null)" || state=""
        case "${state}" in
            ""|completed|failed|killed) continue ;;
            *) _knit_db_update_row "${_KNIT_JOBS_TABLE}" "${id}" "state=killed" \
                   2>/dev/null || true ;;
        esac
    done < "${file}"
}

# ------------------------------------------------------------------------------
# @fn _knit_pilot_teardown_kill()
#
# Tear the pilot down the hard way: tell the daemon to kill every running
# sub-job's process group and drop every queued one (shutdown --kill, which also
# makes the daemon exit), then reconcile the sub-job rows so none is left
# "submitted" or "running". Shared by the --kill-on-exit body-exit policy and the
# pilot's kill-trap. A no-op when no daemon was started (KNIT_PILOT_SOCK unset).
# ------------------------------------------------------------------------------
_knit_pilot_teardown_kill() {
    [[ -n "${KNIT_PILOT_SOCK:-}" ]] || return 0
    "${_KNIT_PILOTD_EXE}" shutdown --kill --socket "${KNIT_PILOT_SOCK}" \
        >> "${KNIT_JOB_PREFIX}/pilot.log" 2>&1 || true
    _knit_pilot_mark_outstanding_killed
}

# ------------------------------------------------------------------------------
# @fn _knit_pilot_killed_trap()
#
# Kill-trap for a pilot job, replacing the generic _knit_job_killed_trap on
# HUP/TERM/USR1 (a cancel, an out-of-time or walltime kill). It first tears the
# daemon down and marks all outstanding sub-jobs killed, so a killed pilot never
# leaves a sub-job "running" or lost, then chains to the generic trap to record
# the pilot itself "killed" and exit. This is also the path a walltime kill
# arriving mid-drain falls through to: the signal interrupts the blocking drain
# in the after-callback and runs this instead.
# ------------------------------------------------------------------------------
_knit_pilot_killed_trap() {
    _knit_pilot_teardown_kill
    _knit_job_killed_trap
}

# ------------------------------------------------------------------------------
# @fn _knit_pilot_after_cb()
#
# After-callback installed by knit_with_pilot, applying the body-exit policy for
# sub-jobs still outstanding when the body returns. Default (drain): ask the
# daemon to run every submitted sub-job to completion, blocking until it has, then
# exit — the safe "don't lose work" default, so each sub-job records its own
# terminal state. With --kill-on-exit: instead kill outstanding (running +
# queued) sub-jobs and mark them killed (_knit_pilot_teardown_kill). Either way
# the daemon is then reaped. A no-op when no daemon was started (KNIT_PILOT_SOCK
# unset). A walltime kill mid-drain does not reach here: the kill-trap
# (_knit_pilot_killed_trap) runs instead.
#
# @param[in] kill_on_exit Non-empty to kill outstanding sub-jobs instead of draining.
# ------------------------------------------------------------------------------
_knit_pilot_after_cb() {
    local kill_on_exit="$1"
    [[ -n "${KNIT_PILOT_SOCK:-}" ]] || return 0
    if [[ -n "${kill_on_exit}" ]]; then
        _knit_pilot_teardown_kill
    else
        # Drain: block until the daemon has run every submitted sub-job to
        # completion, then it exits. Each sub-job records its own terminal state,
        # so no reconciliation is needed on this path.
        "${_KNIT_PILOTD_EXE}" shutdown --socket "${KNIT_PILOT_SOCK}" \
            >> "${KNIT_JOB_PREFIX}/pilot.log" 2>&1 || true
    fi
    if [[ -n "${_KNIT_PILOT_DAEMON_PID:-}" ]]; then
        wait "${_KNIT_PILOT_DAEMON_PID}" 2>/dev/null || true
    fi
    unset KNIT_PILOT KNIT_PILOT_SOCK
}

# ------------------------------------------------------------------------------
# @fn knit_with_pilot()
#
# Declare that the job currently being registered is a pilot job: one that may
# call `knit submit` in its body to schedule sub-jobs onto its own allocation,
# through an in-allocation knit-pilotd daemon instead of the machine scheduler.
# Must be called between knit_register_job and knit_done, at most once per job.
#
# Valid only for jobs. Setups, wrappers, apps, and plain commands are rejected
# with a clear fatal (only a job has an allocation to schedule onto).
#
# Options (flags to the decorator, stored on the command's pilot markers):
#   --exclude-launch-host  Drop the daemon's own host from the node pool when it
#                          is part of the allocation (for systems where the job
#                          script shares the first compute node). A no-op on
#                          separate launch/service-node systems.
#   --kill-on-exit         When the body returns with sub-jobs still outstanding,
#                          kill them instead of draining (the default).
#
# It installs a before-callback that starts the daemon and exports KNIT_PILOT /
# KNIT_PILOT_SOCK, and an after-callback that stops it.
#
# Example:
# ```
# knit_register_job "campaign" _campaign "Run many sub-jobs in one allocation."
# knit_with_pilot
# _campaign() {
#     local ids=""
#     local seed
#     for seed in 1 2 3; do
#         ids+="${ids:+,}$(knit submit --nodes 2 -- simulate --seed "${seed}")"
#     done
#     knit job wait --id "${ids}"
# }
# knit_done
# ```
# ------------------------------------------------------------------------------
knit_with_pilot() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_pilot must be called between a knit_register_job call and knit_done."
    fi
    # Pilot is a job-only decorator. The submit:* gate also rejects setups,
    # wrappers, apps, and plain commands (none mangle to submit:*), each with a
    # clear fatal.
    if [[ "${_KNIT_CURRENT_COMMAND_DEMANGLED}" != submit:* ]]; then
        knit_fatal "knit_with_pilot is valid only for jobs; it must be called between knit_register_job and knit_done."
    fi

    local cmd="${_KNIT_CURRENT_COMMAND}"
    local marker_var="_KNIT_CMD_${cmd}_pilot"
    if [[ -n "${!marker_var:-}" ]]; then
        knit_fatal "knit_with_pilot may be called at most once per job."
    fi

    local exclude_launch_host="" kill_on_exit=""
    while (( $# )); do
        case "$1" in
            --exclude-launch-host) exclude_launch_host=1; shift ;;
            --kill-on-exit)        kill_on_exit=1; shift ;;
            *) knit_fatal "knit_with_pilot: unknown option \"$1\"." ;;
        esac
    done

    printf -v "${marker_var}" '%s' '1'
    [[ -n "${exclude_launch_host}" ]] \
        && printf -v "_KNIT_CMD_${cmd}_pilot_exclude_launch_host" '%s' '1'
    [[ -n "${kill_on_exit}" ]] \
        && printf -v "_KNIT_CMD_${cmd}_pilot_kill_on_exit" '%s' '1'
    knit_trace "Job \"${_KNIT_CURRENT_COMMAND_DEMANGLED}\" is a pilot job."

    # Advertise the pilot in the command's `--help` (see the "Requirements"
    # section rendered by _knit_print_command_usage).
    # shellcheck disable=SC2178 # nameref to the command's notes array
    local -n _notes_ref="_KNIT_CMD_${cmd}_notes"
    _notes_ref+=("Pilot job: may call \"knit submit\" in its body to run sub-jobs on its own allocation.")

    knit_run_before _knit_pilot_before_cb "${exclude_launch_host}"
    knit_run_after  _knit_pilot_after_cb "${kill_on_exit}"
}

# ------------------------------------------------------------------------------
# @fn _knit_pilot_require_sock()
#
# Fatal unless KNIT_PILOT_SOCK names a control socket to talk to the daemon.
# Guards the pilot backend's submit/wait/cancel paths, which are only reachable
# from inside a pilot job body; a missing socket means one of those was reached
# outside a pilot, which is a programming error worth a clear message.
# ------------------------------------------------------------------------------
_knit_pilot_require_sock() {
    if [[ -z "${KNIT_PILOT_SOCK:-}" ]]; then
        knit_fatal "The pilot scheduler backend needs a knit-pilotd control socket (KNIT_PILOT_SOCK is unset); it is only usable inside a pilot job body."
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_pilot_directives()
#
# Emit the batch directives for the pilot backend. A pilot sub-job is launched by
# the daemon as a plain process, not by a batch scheduler, so there are no
# directives and this prints nothing — it exists so every backend honours the
# same contract.
#
# @param[in] arr_name Name of the resolved-options associative array (unused).
# @param[in] jobdir   Job directory (unused).
# ------------------------------------------------------------------------------
_knit_sched_pilot_directives() {
    :
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_pilot_submit()
#
# Submit a built sub-job to the in-allocation knit-pilotd daemon: queue its batch
# script (run as "bash <script>") with the node count resolved for this
# submission, keyed by the sub-job UUID (the job directory's basename), with
# stdout/stderr redirected to the job directory. The request is non-blocking —
# the daemon queues it and returns at once — matching the dispatcher contract
# (the optional --wait is a separate _knit_sched_pilot_wait step). On the daemon
# accepting the request, the sub-job UUID is printed as the backend job id (the
# daemon tracks the sub-job by it, so wait/cancel reference it); a daemon
# rejection propagates as a non-zero status, which the dispatcher treats as a
# scheduler rejection.
#
# @param[in] arr_name Name of the resolved-options associative array.
# @param[in] script   Path to the batch script to queue.
# @param[in] jobdir   Job directory (its basename is the sub-job UUID).
# ------------------------------------------------------------------------------
_knit_sched_pilot_submit() {
    local -n resolved="$1"
    local script="$2"
    local jobdir="$3"
    _knit_pilot_require_sock
    local id
    id="$(basename "${jobdir}")"
    local nodes="${resolved[nodes]:-1}"
    "${_KNIT_PILOTD_EXE}" submit \
        --socket "${KNIT_PILOT_SOCK}" \
        --id "${id}" \
        --nodes "${nodes}" \
        --out "${jobdir}/.stdout" \
        --err "${jobdir}/.stderr" \
        -- bash "${script}" || return $?
    # Track the sub-job so a kill/--kill-on-exit teardown can reconcile it (a
    # queued sub-job that never starts records no terminal state of its own).
    _knit_pilot_record_subjob "${id}"
    printf '%s\n' "${id}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_pilot_submit_cmdline()
#
# Build the pilot backend's submission command into a caller-provided array,
# passed by name, for recording as the row's native-cmd: the daemon submit with
# the node count, launching "bash <script>". The socket, sub-job id, and
# stdout/stderr redirection are knit-managed plumbing (and the id/socket are not
# available here), so — like the local backend's "bash <script>" — they are
# omitted from the recorded command, which captures the essential shape.
#
# @param[out] argv_name Name of the array to fill with the submission argv.
# @param[in] arr_name  Name of the resolved-options associative array.
# @param[in] script    Path to the batch script to queue.
# ------------------------------------------------------------------------------
_knit_sched_pilot_submit_cmdline() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n _submit_argv="$1"
    local -n _resolved="$2"
    local script="$3"
    _submit_argv=("${_KNIT_PILOTD_EXE}" submit --nodes "${_resolved[nodes]:-1}" \
        -- bash "${script}")
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_pilot_wait()
#
# Block until a pilot sub-job reaches a terminal state, by asking the daemon to
# wait on its id. The daemon's client exits 0 when the sub-job completed and
# non-zero when it failed or was killed, which this returns unchanged — the same
# contract the other backends' wait functions honour (knit's own terminal state
# is read from the jobs table afterwards by the caller).
#
# @param[in] id The sub-job UUID recorded in its .job.id by _knit_sched_pilot_submit.
# ------------------------------------------------------------------------------
_knit_sched_pilot_wait() {
    local id="$1"
    _knit_pilot_require_sock
    "${_KNIT_PILOTD_EXE}" wait --socket "${KNIT_PILOT_SOCK}" --id "${id}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_pilot_cancel()
#
# Cancel a pilot sub-job by asking the daemon to terminate it: it kills a running
# sub-job's process group and drops a still-queued one, marking it killed.
# Cancelling a sub-job that is already gone is not an error. Knit's terminal state
# (killed) is recorded by the sub-job's own kill-trap / the daemon.
#
# @param[in] id The sub-job UUID recorded in its .job.id.
# ------------------------------------------------------------------------------
_knit_sched_pilot_cancel() {
    local id="$1"
    _knit_pilot_require_sock
    "${_KNIT_PILOTD_EXE}" cancel --socket "${KNIT_PILOT_SOCK}" --id "${id}" || true
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_pilot_hostfile()
#
# Print the host list for a pilot sub-job: the node subset the daemon assigned it,
# named in KNIT_PILOT_HOSTFILE (one host per line). This is the "raw" host list
# per the dispatcher contract — callers such as knit_job_hostnames deduplicate and
# clean it. Blank lines are dropped. When no readable hostfile is present, warn
# and fall back to this machine's hostname. Reached from _knit_sched_hostfile
# whenever KNIT_PILOT_HOSTFILE is set, so a sub-job places its work onto its own
# subset without needing any pilot environment of its own.
# ------------------------------------------------------------------------------
_knit_sched_pilot_hostfile() {
    if [[ -n "${KNIT_PILOT_HOSTFILE:-}" && -r "${KNIT_PILOT_HOSTFILE}" ]]; then
        grep -v '^[[:space:]]*$' "${KNIT_PILOT_HOSTFILE}"
    else
        knit_warning "Pilot sub-job has no readable KNIT_PILOT_HOSTFILE; reporting the local hostname only."
        hostname
    fi
}
