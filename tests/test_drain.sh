#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # Stub the release primitive with a programmable queue so the loop logic can
    # be exercised without a live scheduler. Each entry is "uuid:rc"; a drained
    # queue yields no UUID and a non-zero status. The real function is called via
    # command substitution and, for the pool, from concurrent background workers,
    # so the queue lives in a file and is popped atomically under a flock. The
    # stub also tracks the peak number of concurrently active claims (in
    # _DRAIN_MAX), and sleeps for _DRAIN_SLEEP seconds while "running" a job so a
    # concurrency test can force workers to overlap.
    _DRAIN_FILE="$(mktemp)"
    _DRAIN_LOCK="$(mktemp)"
    _DRAIN_ACTIVE="$(mktemp)"
    _DRAIN_MAX="$(mktemp)"
    _DRAIN_SLEEP=""
    _drain_program() {
        if (( $# == 0 )); then
            : > "${_DRAIN_FILE}"
        else
            printf '%s\n' "$@" > "${_DRAIN_FILE}"
        fi
        printf '0' > "${_DRAIN_ACTIVE}"
        printf '0' > "${_DRAIN_MAX}"
    }
    _knit_drain_release_next() {
        local entry="" cur mx
        exec 9>"${_DRAIN_LOCK}"; flock 9
        IFS= read -r entry < "${_DRAIN_FILE}" || entry=""
        if [[ -n "${entry}" ]]; then
            sed -i '1d' "${_DRAIN_FILE}"
            cur=$(( $(cat "${_DRAIN_ACTIVE}") + 1 ))
            printf '%s' "${cur}" > "${_DRAIN_ACTIVE}"
            mx=$(cat "${_DRAIN_MAX}")
            (( cur > mx )) && printf '%s' "${cur}" > "${_DRAIN_MAX}"
        fi
        flock -u 9; exec 9>&-
        [[ -z "${entry}" ]] && return 1
        [[ -n "${_DRAIN_SLEEP}" ]] && sleep "${_DRAIN_SLEEP}"
        exec 9>"${_DRAIN_LOCK}"; flock 9
        printf '%s' "$(( $(cat "${_DRAIN_ACTIVE}") - 1 ))" > "${_DRAIN_ACTIVE}"
        flock -u 9; exec 9>&-
        printf '%s\n' "${entry%%:*}"
        return "${entry##*:}"
    }
    _drain_program
}

teardown() {
    rm -f "${_DRAIN_FILE}" "${_DRAIN_LOCK}" "${_DRAIN_ACTIVE}" "${_DRAIN_MAX}"
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

@test "--stop-on-failure with --max-inflight 0 is rejected by the when guard" {
    knit_test_require_jq
    _KNIT_JQ_EXE="jq"
    run knit submit drain --max-inflight 0 --stop-on-failure
    [ "$status" -ne 0 ]
    [[ "$output" == *"stop_on_failure"* ]]
}

# ---------- throttled pool (--max-inflight N > 1) ----------

@test "pool drains all jobs and reports the breakdown" {
    _drain_program a:0 b:0 c:0 d:0 e:0 f:0
    run _knit_drain_pool 3 false ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 6 job(s): 6 completed, 0 failed."* ]]
}

@test "pool keeps concurrency within --max-inflight" {
    _drain_program a:0 b:0 c:0 d:0 e:0 f:0 g:0 h:0 i:0
    _DRAIN_SLEEP="0.15"
    run _knit_drain_pool 3 false ""
    [ "$status" -eq 0 ]
    local mx
    mx=$(cat "${_DRAIN_MAX}")
    [ "$mx" -le 3 ]
    [ "$mx" -ge 2 ]
}

@test "pool --count caps total releases under concurrency" {
    _drain_program a:0 b:0 c:0 d:0 e:0 f:0 g:0 h:0 i:0 j:0
    run _knit_drain_pool 3 false 4
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 4 job(s): 4 completed, 0 failed."* ]]
    # Six entries are left unclaimed.
    [ "$(wc -l < "${_DRAIN_FILE}")" -eq 6 ]
}

@test "pool reports a failure and exits non-zero" {
    _drain_program a:0 b:7 c:0
    run _knit_drain_pool 3 false ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"Released 3 job(s): 2 completed, 1 failed."* ]]
}

@test "pool --stop-on-failure stops launching new jobs after a failure" {
    _drain_program x:7 a:0 b:0 c:0 d:0 e:0 f:0 g:0
    run _knit_drain_pool 2 true ""
    [ "$status" -ne 0 ]
    # Stop kicked in, so the queue was not fully drained.
    [ "$(wc -l < "${_DRAIN_FILE}")" -gt 0 ]
}

# ---------- dispatch (--max-inflight 0 / 1 / N reach the right mode) ----------

@test "submit drain --max-inflight 3 dispatches to the pool" {
    _drain_program a:0 b:0 c:0 d:0
    run _knit_submit_drain --max-inflight 3
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 4 job(s): 4 completed, 0 failed."* ]]
}

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
