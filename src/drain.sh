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
# Print the end-of-run summary to stderr (via the logging system). With no jobs
# released it reports that the queue was empty; in "no-limit" mode it reports
# only the count (no per-job outcome was observed); otherwise it reports the
# completed / failed breakdown. Always returns 0 so it does not disturb the
# caller's exit status.
#
# @param[in] released  Number of jobs released this run.
# @param[in] completed Number that completed successfully (waiting modes).
# @param[in] failed    Number that failed (waiting modes).
# @param[in] mode      "no-limit" or "waiting".
# ------------------------------------------------------------------------------
_knit_drain_report() {
    local released="$1" completed="$2" failed="$3" mode="$4"
    if (( released == 0 )); then
        knit_info "No prepared jobs to release."
        return 0
    fi
    if [[ "${mode}" == "no-limit" ]]; then
        knit_info "Released ${released} job(s)."
    else
        knit_info "Released ${released} job(s): ${completed} completed, ${failed} failed."
    fi
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_drain_nolimit()
#
# No-limit draining (--max-inflight 0): release every matching prepared job,
# back to back, without waiting. Stops when the queue is drained or --count is
# reached. No per-job outcome is observed, so this always succeeds on a clean
# drain.
#
# @param[in] count   Maximum jobs to release, or "" for no cap.
# @param[in] ...     Filter arguments forwarded to _knit_drain_release_next.
# ------------------------------------------------------------------------------
_knit_drain_nolimit() {
    local count="$1"
    shift
    local -a filters=("$@")
    local released=0 uuid
    while [[ -z "${count}" ]] || (( released < count )); do
        uuid="$(_knit_drain_release_next false "${filters[@]}")" || true
        [[ -z "${uuid}" ]] && break
        released=$(( released + 1 ))
    done
    _knit_drain_report "${released}" "" "" "no-limit"
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
# @param[in] ...             Filter arguments forwarded to
#                        _knit_drain_release_next.
# ------------------------------------------------------------------------------
_knit_drain_serial() {
    local stop_on_failure="$1"
    local count="$2"
    shift 2
    local -a filters=("$@")
    local released=0 completed=0 failed=0 uuid rc
    while [[ -z "${count}" ]] || (( released < count )); do
        uuid="$(_knit_drain_release_next true "${filters[@]}")" && rc=0 || rc=$?
        [[ -z "${uuid}" ]] && break
        released=$(( released + 1 ))
        if (( rc == 0 )); then
            completed=$(( completed + 1 ))
        else
            failed=$(( failed + 1 ))
            [[ "${stop_on_failure}" == "true" ]] && break
        fi
    done
    _knit_drain_report "${released}" "${completed}" "${failed}" "waiting"
    (( failed == 0 ))
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
# ------------------------------------------------------------------------------
# @fn _knit_submit_drain()
#
# Entry point for the `submit drain` CLI command. Validates the pacing options
# and dispatches to the mode selected by --max-inflight: 0 drains without
# waiting (_knit_drain_nolimit), 1 drains serially (_knit_drain_serial). Higher
# concurrency is planned but not yet available. The exit status reflects whether
# any released job failed (waiting modes).
#
# Usage:
# ```
# ./exp.sh submit drain [--type <t>] [--group <g>] [--max-inflight <n>] \
#     [--count <n>] [--stop-on-failure]
# ```
# ------------------------------------------------------------------------------
_knit_submit_drain() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local type group max_inflight count stop_on_failure
    type=$(knit_get_parameter "type" "$@") || type=""
    group=$(knit_get_parameter "group" "$@") || group=""
    max_inflight=$(knit_get_parameter "max-inflight" "$@") || max_inflight="1"
    count=$(knit_get_parameter "count" "$@") || count=""
    stop_on_failure=$(knit_get_parameter "stop-on-failure" "$@") || stop_on_failure="false"

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
        _knit_drain_nolimit "${count}" "${filters[@]}"
    elif (( max_inflight == 1 )); then
        _knit_drain_serial "${stop_on_failure}" "${count}" "${filters[@]}"
    else
        # Concurrent draining (--max-inflight > 1) is not implemented yet.
        knit_fatal "submit drain: --max-inflight greater than 1 is not supported yet."
    fi
}
knit_done
