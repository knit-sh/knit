#!/bin/bash

# Showcase for the "recover stuck jobs" recipe: correct jobs stuck at `running`
# or `submitting` (due to a hard SIGKILL that bypassed the kill trap) to their
# true terminal state using `job reconcile` and `submit drain --reconcile`.
#
# This example is runnable: the local backend records a PID as the launcher id,
# so a finished job's PID is provably dead and `job reconcile` maps it to
# `killed`. The check driver exercises the full recover-and-retry lifecycle end
# to end (see reconcile.check.sh).

source knit.sh

knit_set_program_description "Reconcile stuck jobs and retry them."

# START sim
# An ordinary job that always completes. It only does arithmetic, so it runs
# fast on any backend and is suitable as the "victim" job whose state we
# manipulate to simulate a hard-kill scenario.
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
# END sim

knit "$@"
