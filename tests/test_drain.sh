#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # Stub the release primitive with a programmable queue so the loop logic can
    # be exercised without a live scheduler. Each entry is "uuid:rc"; a drained
    # queue yields no UUID and a non-zero status. The real function is called via
    # command substitution (a subshell), so the queue lives in a file that the
    # stub pops from, rather than a shell variable that a subshell could not
    # advance.
    _DRAIN_FILE="$(mktemp)"
    _drain_program() {
        if (( $# == 0 )); then
            : > "${_DRAIN_FILE}"
        else
            printf '%s\n' "$@" > "${_DRAIN_FILE}"
        fi
    }
    _knit_drain_release_next() {
        local entry=""
        IFS= read -r entry < "${_DRAIN_FILE}" || entry=""
        [[ -z "${entry}" ]] && return 1
        sed -i '1d' "${_DRAIN_FILE}"
        printf '%s\n' "${entry%%:*}"
        return "${entry##*:}"
    }
    _drain_program
}

teardown() {
    rm -f "${_DRAIN_FILE}"
    knit_test_db_teardown
}

# ---------- serial mode (--max-inflight 1) ----------

@test "serial drains all jobs and reports success" {
    _drain_program u1:0 u2:0
    run _knit_drain_serial false ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 2 job(s): 2 completed, 0 failed."* ]]
}

@test "serial reports a failure and exits non-zero" {
    _drain_program u1:0 u2:7 u3:0
    run _knit_drain_serial false ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"Released 3 job(s): 2 completed, 1 failed."* ]]
}

@test "serial --count caps the number of releases" {
    _drain_program u1:0 u2:0 u3:0 u4:0
    run _knit_drain_serial false 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 2 job(s): 2 completed, 0 failed."* ]]
}

@test "serial --stop-on-failure halts after the first failure" {
    _drain_program u1:0 u2:7 u3:0
    run _knit_drain_serial true ""
    [ "$status" -ne 0 ]
    # Only two jobs were released (u3 is never claimed).
    [[ "$output" == *"Released 2 job(s): 1 completed, 1 failed."* ]]
}

@test "serial reports an empty queue" {
    _drain_program
    run _knit_drain_serial false ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"No prepared jobs to release."* ]]
}

# ---------- no-limit mode (--max-inflight 0) ----------

@test "no-limit releases every job without observing outcomes" {
    _drain_program u1:0 u2:7 u3:0
    run _knit_drain_nolimit ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 3 job(s)."* ]]
    [[ "$output" != *"completed"* ]]
}

@test "no-limit --count caps the number of releases" {
    _drain_program u1:0 u2:0 u3:0
    run _knit_drain_nolimit 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 2 job(s)."* ]]
}

@test "no-limit reports an empty queue" {
    _drain_program
    run _knit_drain_nolimit ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"No prepared jobs to release."* ]]
}

# ---------- option validation ----------

@test "negative --max-inflight is fatal" {
    run _knit_submit_drain --max-inflight -1
    [ "$status" -ne 0 ]
    [[ "$output" == *"max-inflight"* ]]
}

@test "--count below 1 is fatal" {
    run _knit_submit_drain --max-inflight 1 --count 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"count"* ]]
}

@test "--max-inflight greater than 1 is not supported yet" {
    run _knit_submit_drain --max-inflight 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"not supported yet"* ]]
}

@test "--stop-on-failure with --max-inflight 0 is rejected by the when guard" {
    knit_test_require_jq
    _KNIT_JQ_EXE="jq"
    run knit submit drain --max-inflight 0 --stop-on-failure
    [ "$status" -ne 0 ]
    [[ "$output" == *"stop_on_failure"* ]]
}

# ---------- dispatch (--max-inflight 0 / 1 reach the right mode) ----------

@test "submit drain dispatches to serial by default" {
    _drain_program a:0 b:0
    run _knit_submit_drain
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 2 job(s): 2 completed, 0 failed."* ]]
}

@test "submit drain --max-inflight 0 dispatches to no-limit" {
    _drain_program a:0 b:0
    run _knit_submit_drain --max-inflight 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 2 job(s)."* ]]
    [[ "$output" != *"completed"* ]]
}
