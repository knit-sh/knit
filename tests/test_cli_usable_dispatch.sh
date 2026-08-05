#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# A never-usable predicate and a body that records (via a file marker) whether it
# ran; the marker must never appear because the dispatcher pre-check fails first.
_ud_no() { return 1; }
_ud_body() { : > "${BATS_TEST_TMPDIR}/ran"; }

@test "submit pre-checks usability before scheduling" {
    knit_register_job "ud_job" _ud_body "A job."
    knit_usable_if _ud_no "job not ready"
    knit_done
    rm -f "${BATS_TEST_TMPDIR}/ran"
    run _knit_submit -- ud_job
    [ "$status" -eq 1 ]
    [[ "$output" == *'Command "submit:ud_job" cannot run: job not ready'* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/ran" ]
}

@test "run pre-checks usability before launching" {
    knit_register_app "ud_app" _ud_body "An app."
    knit_usable_if _ud_no "app not ready"
    knit_done
    rm -f "${BATS_TEST_TMPDIR}/ran"
    export KNIT_JOB_PREFIX="${BATS_TEST_TMPDIR}/job"
    run _knit_run -- ud_app
    unset KNIT_JOB_PREFIX
    [ "$status" -eq 1 ]
    [[ "$output" == *'Command "run:ud_app" cannot run: app not ready'* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/ran" ]
}

@test "setup pre-checks usability before creating the instance directory" {
    knit_register_setup "ud_setup" _ud_body "A setup."
    knit_usable_if _ud_no "setup not ready"
    knit_done
    rm -f "${BATS_TEST_TMPDIR}/ran"
    run _knit_setup --name ud_inst -- ud_setup
    [ "$status" -eq 1 ]
    [[ "$output" == *'Command "setup:ud_setup" cannot run: setup not ready'* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/ran" ]
}
