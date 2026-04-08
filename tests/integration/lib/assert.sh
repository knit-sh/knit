#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# assert.sh — Lightweight assertion helpers for knit integration tests.
#
# Source this file at the top of each test.sh:
#   source /shared/knit/tests/integration/lib/assert.sh
#
# Each helper prints "PASS: <msg>" on success or "FAIL: <msg>" and exits 1 on
# failure.  The test name is taken from the calling test.sh path when possible.
# ------------------------------------------------------------------------------

# Count of passed/failed assertions (informational; test.sh exit code is the
# authoritative signal for the Makefile).
__ASSERT_PASS=0
__ASSERT_FAIL=0

__assert_pass() {
    local msg="$1"
    __ASSERT_PASS=$(( __ASSERT_PASS + 1 ))
    printf 'PASS: %s\n' "${msg}"
}

__assert_fail() {
    local msg="$1"
    __ASSERT_FAIL=$(( __ASSERT_FAIL + 1 ))
    printf 'FAIL: %s\n' "${msg}" >&2
    exit 1
}

# ------------------------------------------------------------------------------
# check_eq <actual> <expected> [msg]
# Fails if the two strings are not equal.
# ------------------------------------------------------------------------------
check_eq() {
    local actual="$1"
    local expected="$2"
    local msg="${3:-"expected \"${expected}\", got \"${actual}\""}"
    if [[ "${actual}" == "${expected}" ]]; then
        __assert_pass "${msg}"
    else
        __assert_fail "${msg} (actual=\"${actual}\" expected=\"${expected}\")"
    fi
}

# ------------------------------------------------------------------------------
# check_file <path> [msg]
# Fails if the file does not exist or is empty.
# ------------------------------------------------------------------------------
check_file() {
    local path="$1"
    local msg="${2:-"file exists and is non-empty: ${path}"}"
    if [[ -s "${path}" ]]; then
        __assert_pass "${msg}"
    else
        __assert_fail "${msg}"
    fi
}

# ------------------------------------------------------------------------------
# check_dir <path> [msg]
# Fails if the directory does not exist.
# ------------------------------------------------------------------------------
check_dir() {
    local path="$1"
    local msg="${2:-"directory exists: ${path}"}"
    if [[ -d "${path}" ]]; then
        __assert_pass "${msg}"
    else
        __assert_fail "${msg}"
    fi
}

# ------------------------------------------------------------------------------
# check_exec <path> [msg]
# Fails if the file does not exist or is not executable.
# ------------------------------------------------------------------------------
check_exec() {
    local path="$1"
    local msg="${2:-"file is executable: ${path}"}"
    if [[ -x "${path}" ]]; then
        __assert_pass "${msg}"
    else
        __assert_fail "${msg}"
    fi
}

# ------------------------------------------------------------------------------
# check_sqlite <db> <query> <expected> [msg]
# Runs <query> against <db> with sqlite3 and fails if the output != <expected>.
# ------------------------------------------------------------------------------
check_sqlite() {
    local db="$1"
    local query="$2"
    local expected="$3"
    local msg="${4:-"sqlite query: ${query}"}"
    local actual
    actual=$("${__ASSERT_SQLITE3:-sqlite3}" "${db}" "${query}" 2>&1)
    if [[ "${actual}" == "${expected}" ]]; then
        __assert_pass "${msg}"
    else
        __assert_fail "${msg} (actual=\"${actual}\" expected=\"${expected}\")"
    fi
}

# ------------------------------------------------------------------------------
# check_grep <pattern> <file> [msg]
# Fails if <pattern> is not found in <file> (grep -q).
# ------------------------------------------------------------------------------
check_grep() {
    local pattern="$1"
    local file="$2"
    local msg="${3:-"pattern \"${pattern}\" found in ${file}"}"
    if grep -q "${pattern}" "${file}" 2>/dev/null; then
        __assert_pass "${msg}"
    else
        __assert_fail "${msg}"
    fi
}

# ------------------------------------------------------------------------------
# fail <msg>
# Unconditional failure.
# ------------------------------------------------------------------------------
fail() {
    local msg="${1:-"unconditional failure"}"
    __assert_fail "${msg}"
}

# ------------------------------------------------------------------------------
# assert_summary
# Print a summary line.  Call at the end of test.sh (optional).
# ------------------------------------------------------------------------------
assert_summary() {
    printf 'Results: %d passed, %d failed\n' "${__ASSERT_PASS}" "${__ASSERT_FAIL}"
}
