#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# doc-check-lib.sh
#
# Helpers sourced by documentation example drivers (docs/source/_code/*.check.sh).
# A driver runs with its working directory set to a throwaway copy of the example
# (knit.sh + the experiment script side by side), the experiment's filename in
# $EXP, and this library's path in $KNIT_DOC_LIB.
#
# The library forces the portable local backend so every documented example runs
# on any CI runner with no scheduler and no MPI. Drivers are NOT shown in the
# documentation; they only exercise the shown experiment.
# ----------------------------------------------------------------------------

# Degrade scheduler detection to the local backend regardless of what happens to
# be installed on the host running the docs check.
export _KNIT_DETECTED_JOB_MANAGER="<unknown>"

# Generate strictly-increasing uuids so "ORDER BY id" equals creation order and
# examples are deterministic even on a fast runner where several entities land in
# one millisecond (see _KNIT_UUIDV7_MONOTONIC). Exported so it reaches the
# experiment subprocess the drivers run.
export _KNIT_UUIDV7_MONOTONIC="1"

_dc_fail=0

# Bootstrap builds sqlite from source and downloads jq by default — far too slow,
# and network-dependent, to repeat for every documented example on one shared CI
# runner. That runner always installs a system sqlite3 and jq, so the docs check
# symlinks those with --use-system-sqlite/--use-system-jq. A driver that must
# exercise bootstrap's own provisioning sets _DC_BOOTSTRAP_SYSTEM_TOOLS=0 and
# manages the flags itself.
: "${_DC_BOOTSTRAP_SYSTEM_TOOLS:=1}"

# @fn exp()
# Run the experiment under test with the given arguments. A real `bootstrap` call
# (not `--help`) is routed to the system sqlite3/jq unless the driver opted out
# via _DC_BOOTSTRAP_SYSTEM_TOOLS=0.
exp() {
    if [[ "${_DC_BOOTSTRAP_SYSTEM_TOOLS}" == 1 && "${1:-}" == bootstrap \
          && " $* " != *" --help "* ]]; then
        ./"${EXP}" "$@" --use-system-sqlite --use-system-jq
    else
        ./"${EXP}" "$@"
    fi
}

# @fn check_eq()
# Assert that two strings are equal. Usage: check_eq <actual> <expected> <message>
check_eq() {
    if [[ "$1" == "$2" ]]; then
        printf '  ok   %s\n' "$3"
    else
        printf '  FAIL %s (got "%s", want "%s")\n' "$3" "$1" "$2"
        _dc_fail=1
    fi
}

# @fn check_contains()
# Assert that a string contains a substring.
# Usage: check_contains <haystack> <needle> <message>
check_contains() {
    if [[ "$1" == *"$2"* ]]; then
        printf '  ok   %s\n' "$3"
    else
        printf '  FAIL %s (missing "%s")\n' "$3" "$2"
        _dc_fail=1
    fi
}

# @fn dc_summary()
# Exit non-zero if any assertion in this driver failed.
dc_summary() {
    if [[ ${_dc_fail} -ne 0 ]]; then
        echo "  example FAILED"
        exit 1
    fi
}
