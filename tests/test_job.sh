#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    unset KNIT_JOB_PREFIX
    unset KNIT_SETUP_PREFIX
    knit_test_db_teardown
}

# ---------- submit command registration ----------

@test "submit command is registered" {
    _knit_set_find _KNIT_COMMANDS "submit"
}

@test "submit command uses the \"Jobs\" subcommand title" {
    [ "${_KNIT_CMD_submit_subcommand_title}" = "Jobs" ]
}

# ---------- knit_register_job ----------

@test "knit_register_job adds name to _KNIT_JOBS" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    [[ -v _KNIT_JOBS["myjob"] ]]
}

@test "knit_register_job registers submit:<name> command" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    _knit_set_find _KNIT_COMMANDS "submit__1__myjob"
}

@test "knit_register_job creates DB table named after the job" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    local result
    result=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='myjob';")
    [ "$result" -eq 1 ]
}

# ---------- knit_with_setup ----------

@test "knit_with_setup records the required setup type for the job" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_done
    [ "${_KNIT_CMD_submit__1__myjob_setup}" = "mcenv" ]
}

@test "job --help shows the setup requirement and the parent --setup option" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_with_optional "samples:integer" "10" "Number of samples."
    knit_done
    local result
    result=$(_knit_invoke_command "submit" "myjob" "--help")
    [[ "$result" == *"submit [OPTIONS] -- myjob [OPTIONS]"* ]]
    [[ "$result" == *"--samples"* ]]
    [[ "$result" == *"submit options"* ]]
    [[ "$result" == *"--setup"* ]]
    [[ "$result" == *"Requirements"* ]]
    [[ "$result" == *'Requires a --setup built by the "mcenv" setup.'* ]]
}

@test "job --help omits Requirements when the job needs no setup" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_optional "samples:integer" "10" "Number of samples."
    knit_done
    local result
    result=$(_knit_invoke_command "submit" "myjob" "--help")
    [[ "$result" == *"submit [OPTIONS] -- myjob [OPTIONS]"* ]]
    [[ "$result" != *"Requirements"* ]]
}

@test "a job without knit_with_setup has no setup marker" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    [[ ! -v _KNIT_CMD_submit__1__myjob_setup ]]
}

@test "knit_with_setup rejects an invalid setup type name" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    run knit_with_setup "not a name"
    [ "$status" -ne 0 ]
    knit_done
}

@test "knit_with_setup fails when not registering a job" {
    run knit_with_setup "mcenv"
    [ "$status" -ne 0 ]
}

@test "knit_with_setup succeeds inside a non-job command registration" {
    # knit_with_setup is no longer job-only: a plain command may declare it and
    # gains a --setup option plus the generic setup marker (see test_setup.sh for
    # the full generic behavior).
    _test_fn() { :; }
    knit_register "notajob" "_test_fn" "A plain command."
    knit_with_setup "mcenv"
    knit_done
    [ "${_KNIT_CMD_notajob_setup}" = "mcenv" ]
    _knit_set_find "_KNIT_CMD_notajob_optional" "setup"
}

@test "knit_register_job installs before callback" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "submit:myjob")
    local cb_content
    eval "cb_content=\"\${_KNIT_CMD_${cmd}_before_cb[*]}\""
    [[ "${cb_content}" == *_knit_job_before_cb* ]]
}

@test "knit_register_job installs after callback" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "submit:myjob")
    local cb_content
    eval "cb_content=\"\${_KNIT_CMD_${cmd}_after_cb[*]}\""
    [[ "${cb_content}" == *_knit_job_after_cb* ]]
}

# Create a minimal jobs table and seed one row. The lifecycle callbacks update
# the "state" column and _knit_job_record_hostnames updates "hostnames", both by
# id, so a three-column table is enough here.
_seed_jobs() {
    local id="$1" state="$2"
    sqlite3 "${_KNIT_DATABASE}" \
        "CREATE TABLE IF NOT EXISTS jobs (id TEXT, state TEXT, hostnames TEXT);"
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO jobs (id, state, hostnames) VALUES ('${id}', '${state}', '');"
}

_state_of() {
    sqlite3 "${_KNIT_DATABASE}" "SELECT state FROM jobs WHERE id='$1';"
}

_hostnames_of() {
    sqlite3 "${_KNIT_DATABASE}" "SELECT hostnames FROM jobs WHERE id='$1';"
}

# Replace the backend host source with a fixture exercising the two raw hostfile
# shapes knit_job_hostnames normalises: a ":N" slot suffix and a repeated host.
_stub_hostfile() {
    _knit_sched_hostfile() { printf 'nodeA\nnodeA:4\nnodeB\n'; }
}

# ---------- _knit_job_set_state ----------

@test "set state is a no-op when KNIT_JOB_PREFIX is not set" {
    unset KNIT_JOB_PREFIX
    run _knit_job_set_state "running"
    [ "$status" -eq 0 ]
}

@test "set state updates the jobs row keyed by the job UUID" {
    export KNIT_JOB_PREFIX="${_KNIT_TEST_TMPDIR}/abc-uuid"
    _seed_jobs "abc-uuid" "submitted"
    _knit_job_set_state "running"
    [ "$(_state_of "abc-uuid")" = "running" ]
}

# ---------- _knit_job_record_hostnames ----------

@test "record hostnames is a no-op when KNIT_JOB_PREFIX is not set" {
    unset KNIT_JOB_PREFIX
    _stub_hostfile
    run _knit_job_record_hostnames
    [ "$status" -eq 0 ]
}

@test "record hostnames writes the deduplicated comma-separated list by UUID" {
    export KNIT_JOB_PREFIX="${_KNIT_TEST_TMPDIR}/abc-uuid"
    _seed_jobs "abc-uuid" "running"
    _stub_hostfile
    _knit_job_record_hostnames
    [ "$(_hostnames_of "abc-uuid")" = "nodeA,nodeB" ]
}

# ---------- _knit_job_before_cb ----------

@test "job before callback fails when KNIT_JOB_PREFIX is not set" {
    unset KNIT_JOB_PREFIX
    run _knit_job_before_cb
    [ "$status" -ne 0 ]
}

@test "job before callback sources .activate.sh, marks running, records hosts" {
    export KNIT_JOB_PREFIX="${_KNIT_TEST_TMPDIR}/job"
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    printf 'export _KNIT_JOB_CANARY=activated\n' > "${KNIT_SETUP_PREFIX}/.activate.sh"
    _seed_jobs "job" "submitted"
    _stub_hostfile
    _knit_job_before_cb
    [ "${_KNIT_JOB_CANARY}" = "activated" ]
    [ "$(_state_of "job")" = "running" ]
    [ "$(_hostnames_of "job")" = "nodeA,nodeB" ]
    unset _KNIT_JOB_CANARY
}

@test "job before callback marks running without sourcing when there is no setup" {
    export KNIT_JOB_PREFIX="${_KNIT_TEST_TMPDIR}/job"
    unset KNIT_SETUP_PREFIX
    _seed_jobs "job" "submitted"
    _stub_hostfile
    run _knit_job_before_cb
    [ "$status" -eq 0 ]
    [ "$(_state_of "job")" = "running" ]
}

@test "job before callback installs the kill trap on HUP, TERM and USR1" {
    export KNIT_JOB_PREFIX="${_KNIT_TEST_TMPDIR}/job"
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    : > "${KNIT_SETUP_PREFIX}/.activate.sh"
    _seed_jobs "job" "submitted"
    _stub_hostfile
    _knit_job_before_cb
    trap -p HUP | grep -q _knit_job_killed_trap
    trap -p TERM | grep -q _knit_job_killed_trap
    trap -p USR1 | grep -q _knit_job_killed_trap
}

# ---------- _knit_job_killed_trap ----------

@test "kill trap records the job as killed and exits non-zero" {
    export KNIT_JOB_PREFIX="${_KNIT_TEST_TMPDIR}/job"
    _seed_jobs "job" "running"
    run _knit_job_killed_trap
    [ "$status" -eq 143 ]
    [ "$(_state_of "job")" = "killed" ]
}

# ---------- _knit_job_after_cb ----------

@test "job after callback marks the job completed" {
    export KNIT_JOB_PREFIX="${_KNIT_TEST_TMPDIR}/job"
    _seed_jobs "job" "running"
    _knit_job_after_cb
    [ "$(_state_of "job")" = "completed" ]
}

@test "job after callback is a no-op when not running as a job" {
    unset KNIT_JOB_PREFIX
    run _knit_job_after_cb
    [ "$status" -eq 0 ]
}
