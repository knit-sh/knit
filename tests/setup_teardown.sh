# shellcheck shell=bash
#
# Shared setup/teardown helpers for the bats unit tests.
#
# This file is NOT itself a bats test file (it does not match tests/test_*.sh),
# so it is never executed as a test. Individual test files source it from their
# own setup()/teardown() and call the helpers below. Each file keeps a thin
# setup()/teardown() so it can add any file-specific extras.
#
# Source it from a test file with:
#     source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
#
# The helpers assume bats runs with the repository root as the working
# directory (as `make check-unit` does), matching the plain `source knit.sh`
# used throughout the test suite.

# Skip the current test if the sqlite3 executable is not on PATH.
knit_test_require_sqlite() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi
}

# Skip the current test if the jq executable is not on PATH.
knit_test_require_jq() {
    if ! command -v jq &>/dev/null; then
        skip "jq not available"
    fi
}

# Source knit.sh with bats's per-command DEBUG trace temporarily disabled.
#
# bats runs each test with `set -T` (functrace) and a DEBUG trap that walks the
# call stack on every command it executes. knit.sh runs on the order of 18,000
# commands at load time (all the command registration), so leaving the trace
# active while sourcing it makes `source knit.sh` dominate each test's runtime
# (~4s instead of ~0.5s). This helper turns off the DEBUG trap and functrace
# only around the source, then restores both, so failures in the test body
# still get accurate line and stack-trace reporting.
knit_test_source_knit() {
    local _knit_saved_debug_trap _knit_saved_functrace
    _knit_saved_debug_trap="$(trap -p DEBUG)"
    case $- in
        *T*) _knit_saved_functrace=1 ;;
        *)   _knit_saved_functrace="" ;;
    esac

    trap - DEBUG
    set +T

    source knit.sh

    [[ -n "${_knit_saved_functrace}" ]] && set -T
    # Reinstall bats's DEBUG trap verbatim (a no-op when there was none, e.g.
    # when a test file is run directly rather than under bats). eval is required
    # here: `trap -p` emits a ready-to-run `trap -- '...' DEBUG` command and
    # there is no non-eval way to reinstate a saved trap.
    eval "${_knit_saved_debug_trap}"
}

# Source knit.sh, point it at a throwaway sqlite database, and mark the
# framework as bootstrapped so commands that require a live DB work. Callers
# that need sqlite3 should invoke knit_test_require_sqlite first.
knit_test_db_setup() {
    knit_test_source_knit

    # Override the sqlite executable and database path for testing.
    _KNIT_SQLITE_EXE="sqlite3"
    _KNIT_DATABASE="$(mktemp --suffix=.db)"

    # Satisfy the bootstrap check — tests using this helper work with a live DB.
    _KNIT_IS_BOOTSTRAPPED="1"
}

# Remove the throwaway database created by knit_test_db_setup and clear the
# bootstrap flag.
knit_test_db_teardown() {
    rm -f "${_KNIT_DATABASE}"
    _KNIT_IS_BOOTSTRAPPED=""
}
