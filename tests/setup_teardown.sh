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

# Source knit.sh, point it at a throwaway sqlite database, and mark the
# framework as bootstrapped so commands that require a live DB work. Callers
# that need sqlite3 should invoke knit_test_require_sqlite first.
knit_test_db_setup() {
    source knit.sh

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
