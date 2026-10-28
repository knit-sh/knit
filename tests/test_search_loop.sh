#!/usr/bin/env bats

# search-core M6: knit_search_loop drives a proposer over a budget of trials,
# keeps up to --parallel in flight, detects completion (job mode via jobs.state,
# app mode via wait -n), runs the optional collector, and routes a finished
# trial's outcome to the proposer's observe callback (whose return value is the
# failure policy). Tests use a trivial fake proposer and a stubbed launch.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    _KNIT_RECORDING_SUPPRESSED=""
    sqlite3 "${_KNIT_DATABASE}" "CREATE TABLE IF NOT EXISTS jobs (id TEXT, state TEXT);"
    OBS_LOG="$(mktemp)"
    COLLECT_LOG="$(mktemp)"
    CONC_LOG="$(mktemp)"
    __fake_total=0
    __fake_asked=0
    __fake_policy="continue"
    __fake_fail_n=""
}

teardown() {
    rm -f "${OBS_LOG}" "${COLLECT_LOG}" "${CONC_LOG}"
    knit_test_db_teardown
}

# ---------- fake proposer (a stateless counter) ----------

# ask yields __fake_total trials, each tagged "trial-N" with argv "cmd --n N".
_fake_ask() {
    local -n _t=$1
    local -n _a=$2
    if (( __fake_asked >= __fake_total )); then
        return 1
    fi
    __fake_asked=$(( __fake_asked + 1 ))
    _t="trial-${__fake_asked}"
    _a=( cmd --n "${__fake_asked}" )
    return 0
}

# observe logs the outcome; under policy "stop" it aborts on a failed child.
_fake_observe() {
    local tag="$1" uuid="$2" status="$3" objective="$4"
    printf '%s %s %s %s\n' "${tag}" "${uuid}" "${status}" "${objective}" >> "${OBS_LOG}"
    if [[ "${__fake_policy}" == "stop" && "${status}" == "failed" ]]; then
        return 1
    fi
    return 0
}

# collect records that it ran and returns a per-uuid objective.
_fake_collect() {
    local -n _o=$1
    local uuid="$2"
    printf '%s\n' "${uuid}" >> "${COLLECT_LOG}"
    _o="obj-${uuid}"
}

# Stubbed launch for the logic tests: records a terminal jobs row immediately
# ("failed" for trial __fake_fail_n, else "completed"), so a poll reaps it at
# once with no sleeping.
_stub_launch_done() {
    local -n _u=$1; shift
    local n="$3"                 # argv is: cmd --n N
    local uuid="job-${n}"
    _u="${uuid}"
    local state="completed"
    [[ -n "${__fake_fail_n}" && "${n}" == "${__fake_fail_n}" ]] && state="failed"
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO jobs (id, state) VALUES ('${uuid}', '${state}');"
    return 0
}

# ---------- N trials run, collector fires, outcomes observed (job mode) ----------

@test "job mode runs every trial and fires the collector when given" {
    __fake_total=3
    knit_search_launch() { _stub_launch_done "$@"; }

    run knit_search_loop --mode job --parallel 2 \
        --ask _fake_ask --observe _fake_observe --collect _fake_collect
    [ "$status" -eq 0 ]
    # Every trial was observed, each as completed with its collected objective.
    [ "$(wc -l < "${OBS_LOG}")" -eq 3 ]
    [ "$(grep -c ' completed obj-job-' "${OBS_LOG}")" -eq 3 ]
    # The collector ran once per finished trial.
    [ "$(wc -l < "${COLLECT_LOG}")" -eq 3 ]
}

@test "job mode omits the objective when no collector is given" {
    __fake_total=2
    knit_search_launch() { _stub_launch_done "$@"; }

    run knit_search_loop --mode job --parallel 2 \
        --ask _fake_ask --observe _fake_observe
    [ "$status" -eq 0 ]
    [ "$(wc -l < "${OBS_LOG}")" -eq 2 ]
    # Trailing field (objective) is empty: lines end with "completed ".
    [ "$(grep -c ' completed $' "${OBS_LOG}")" -eq 2 ]
    [ ! -s "${COLLECT_LOG}" ]
}

# ---------- failure policy via observe's verdict ----------

@test "job mode: a failed child aborts the campaign under the stop policy" {
    __fake_total=5
    __fake_policy="stop"
    __fake_fail_n=2
    knit_search_launch() { _stub_launch_done "$@"; }

    run knit_search_loop --mode job --parallel 1 \
        --ask _fake_ask --observe _fake_observe
    # The loop reports the abort...
    [ "$status" -eq 1 ]
    # ...after observing exactly trials 1 (completed) and 2 (failed); 3..5 never ran.
    [ "$(wc -l < "${OBS_LOG}")" -eq 2 ]
    [ "$(grep -c ' failed $' "${OBS_LOG}")" -eq 1 ]
}

@test "job mode: a failed child keeps going under the continue policy" {
    __fake_total=5
    __fake_policy="continue"
    __fake_fail_n=2
    knit_search_launch() { _stub_launch_done "$@"; }

    run knit_search_loop --mode job --parallel 1 \
        --ask _fake_ask --observe _fake_observe
    [ "$status" -eq 0 ]
    # All five ran despite the failure; exactly one was failed.
    [ "$(wc -l < "${OBS_LOG}")" -eq 5 ]
    [ "$(grep -c ' failed $' "${OBS_LOG}")" -eq 1 ]
}

# ---------- --parallel caps in-flight count (job mode, deterministic) ----------

@test "job mode caps the in-flight count at --parallel" {
    __fake_total=6
    # Launch records a non-terminal "running" row and logs how many are running
    # (a deterministic in-flight gauge, since job mode manages the set between
    # polls with no real concurrency).
    knit_search_launch() {
        local -n _u=$1; shift
        local n="$3"
        local uuid="job-${n}"
        _u="${uuid}"
        sqlite3 "${_KNIT_DATABASE}" \
            "INSERT INTO jobs (id, state) VALUES ('${uuid}', 'running');"
        sqlite3 "${_KNIT_DATABASE}" \
            "SELECT COUNT(*) FROM jobs WHERE state='running';" >> "${CONC_LOG}"
    }
    # Stubbed sleep stands in for the scheduler + compute-side terminal write: it
    # completes the oldest still-running trial, so the loop drains one per poll.
    sleep() {
        local one
        one="$(sqlite3 "${_KNIT_DATABASE}" \
            "SELECT id FROM jobs WHERE state='running' ORDER BY rowid LIMIT 1;")"
        [[ -n "${one}" ]] && sqlite3 "${_KNIT_DATABASE}" \
            "UPDATE jobs SET state='completed' WHERE id='${one}';"
    }

    run knit_search_loop --mode job --parallel 2 --poll 0 \
        --ask _fake_ask --observe _fake_observe
    [ "$status" -eq 0 ]
    # Every trial was observed.
    [ "$(wc -l < "${OBS_LOG}")" -eq 6 ]
    # The in-flight gauge never exceeded --parallel, and did reach it.
    local maxc
    maxc="$(sort -n "${CONC_LOG}" | tail -1)"
    [ "${maxc}" -eq 2 ]
}

# ---------- a proposer that declines mid-flight still finishes (job mode) ----------

# Regression: in parallel mode the loop used to treat a single declined ask as a
# permanent stop, so a model-based proposer (e.g. Ax) that declines while trials
# are in flight and proposes again once their results arrive ended the campaign
# early. The loop must keep going until the proposer is genuinely exhausted.
@test "job mode: a proposer that declines while trials are in flight still runs them all" {
    __fake_total=6
    __fake_launched=0
    __fake_observed=0
    # Pausing proposer: yields the next trial only when no launched trial is
    # still awaiting its result (launched == observed); otherwise it declines.
    # This mimics Ax pausing during its model phase while trials are pending.
    _pausing_ask() {
        local -n _t=$1
        local -n _a=$2
        (( __fake_launched >= __fake_total )) && return 1
        (( __fake_launched > __fake_observed )) && return 1
        __fake_launched=$(( __fake_launched + 1 ))
        _t="trial-${__fake_launched}"
        _a=( cmd --n "${__fake_launched}" )
        return 0
    }
    _counting_observe() {
        local tag="$1" uuid="$2" status="$3" objective="$4"
        __fake_observed=$(( __fake_observed + 1 ))
        printf '%s %s %s %s\n' "${tag}" "${uuid}" "${status}" "${objective}" >> "${OBS_LOG}"
        return 0
    }
    knit_search_launch() { _stub_launch_done "$@"; }

    run knit_search_loop --mode job --parallel 4 --poll 0 \
        --ask _pausing_ask --observe _counting_observe
    [ "$status" -eq 0 ]
    # All six trials ran despite the proposer declining after every launch.
    [ "$(wc -l < "${OBS_LOG}")" -eq 6 ]
}

# ---------- app mode reaps PIDs with wait -n ----------

@test "app mode reaps every backgrounded run and observes its status" {
    __fake_total=4
    # Stub a blocking run: set the child id and return success (the loop
    # backgrounds this and reaps it via wait -n).
    knit_search_launch() {
        local -n _u=$1; shift
        local n="$3"
        _u="app-${n}"
        return 0
    }

    run knit_search_loop --mode app --parallel 2 \
        --ask _fake_ask --observe _fake_observe
    [ "$status" -eq 0 ]
    [ "$(wc -l < "${OBS_LOG}")" -eq 4 ]
    [ "$(grep -c ' completed $' "${OBS_LOG}")" -eq 4 ]
    # Each reaped child carried its own recorded row id through the temp file.
    [ "$(grep -c ' app-' "${OBS_LOG}")" -eq 4 ]
}

@test "app mode: a proposer that declines while runs are in flight still runs them all" {
    __fake_total=5
    __fake_launched=0
    __fake_observed=0
    _pausing_ask() {
        local -n _t=$1
        local -n _a=$2
        (( __fake_launched >= __fake_total )) && return 1
        (( __fake_launched > __fake_observed )) && return 1
        __fake_launched=$(( __fake_launched + 1 ))
        _t="trial-${__fake_launched}"
        _a=( cmd --n "${__fake_launched}" )
        return 0
    }
    _counting_observe() {
        local tag="$1" uuid="$2" status="$3" objective="$4"
        __fake_observed=$(( __fake_observed + 1 ))
        printf '%s %s %s %s\n' "${tag}" "${uuid}" "${status}" "${objective}" >> "${OBS_LOG}"
        return 0
    }
    knit_search_launch() {
        local -n _u=$1; shift
        local n="$3"
        _u="app-${n}"
        return 0
    }

    run knit_search_loop --mode app --parallel 4 \
        --ask _pausing_ask --observe _counting_observe
    [ "$status" -eq 0 ]
    [ "$(wc -l < "${OBS_LOG}")" -eq 5 ]
}

@test "app mode marks a non-zero run as failed" {
    __fake_total=1
    knit_search_launch() {
        local -n _u=$1; shift
        _u="app-x"
        return 3
    }

    run knit_search_loop --mode app --parallel 1 \
        --ask _fake_ask --observe _fake_observe
    [ "$status" -eq 0 ]
    [ "$(grep -c ' failed $' "${OBS_LOG}")" -eq 1 ]
}

# ---------- option validation ----------

@test "loop rejects a missing mode" {
    run knit_search_loop --ask _fake_ask --observe _fake_observe
    [ "$status" -eq 1 ]
    [[ "$output" == *"--mode"* ]]
}

@test "loop rejects a non-positive --parallel" {
    run knit_search_loop --mode job --parallel 0 \
        --ask _fake_ask --observe _fake_observe
    [ "$status" -eq 1 ]
    [[ "$output" == *"parallel"* ]]
}

@test "loop rejects an unknown option" {
    run knit_search_loop --mode job --bogus x \
        --ask _fake_ask --observe _fake_observe
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option"* ]]
}
