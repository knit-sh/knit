#!/bin/bash

# Showcase for the "retry failed jobs" recipe: re-queue terminal-failed jobs with
# `job reset` / `submit drain --retry`. A prepared batch is drained; a job that
# fails is re-queued and retried, so the prepared queue is the durable backlog
# that survives a drainer dying (e.g. a pilot killed at walltime).
#
# This example is runnable: preparing never contacts a scheduler, and releasing a
# job dispatches it to the portable local backend, so check-docs drives the whole
# prepare -> drain -> retry -> complete lifecycle end to end (see retry.check.sh).

source knit.sh

knit_set_program_description "Prepare a batch, drain it, and retry what failed."

# An ordinary job for the prepared batch. It only does arithmetic, so it runs
# fast anywhere and always completes.
@job "sim" "Run one trivial simulation."
@without_setup
@with_optional "n:integer"      "1"  "Number of steps to run."
@with_table
@with_output   "result:integer" "0"  "Twice the step count (a stand-in result)."
_sim() {
    local n
    n=$(knit_get_parameter "n" "$@")
    knit_output "result" "$(( n * 2 ))"
    printf 'sim: n=%s result=%s\n' "${n}" "$(( n * 2 ))"
}
@done

# START flaky
# A job that fails on its first attempt and succeeds on the retry. It records an
# ".attempted" marker in its own directory (KNIT_JOB_PREFIX), which `job reset`
# preserves, so the second run sees the marker and completes. A real job does not
# fail on purpose; this one stands in for one killed by a walltime limit.
@job "flaky" "Fail on the first attempt, succeed on the retry."
@without_setup
_flaky() {
    if [[ -f "${KNIT_JOB_PREFIX}/.attempted" ]]; then
        printf 'flaky: retry attempt, succeeding\n'
        return 0
    fi
    : > "${KNIT_JOB_PREFIX}/.attempted"
    printf 'flaky: first attempt, failing\n'
    return 1
}
@done
# END flaky

knit "$@"
