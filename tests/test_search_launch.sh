#!/usr/bin/env bats

# search-core M5: _knit_search_launch invokes a downstream knit command line
# in-process and returns the child's recorded row id by nameref. The provenance
# "call" edge parent -> child is written by knit's existing recording, not by
# the launch helper, so these tests assert the edge too.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    _KNIT_RECORDING_SUPPRESSED=""
    # Create the edge table up front so an assertion can query __provenance__.
    _knit_prov_create_table
}

teardown() {
    knit_test_db_teardown
}

# ---------- bare command line ----------

@test "launch records the child row and returns its id by nameref" {
    knit_register "trial" _l_trial_fn "Trial."
    knit_with_table "trials"
    _l_trial_fn() { :; }
    knit_done

    knit_register "driver" _l_driver_fn "Driver."
    knit_with_table "drivers"
    _l_driver_fn() {
        local kid
        _knit_search_launch kid trial
        __l_kid="${kid}"
    }
    knit_done

    _knit_invoke_command "driver"

    local trial_id
    trial_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM trials;")
    [ -n "${__l_kid}" ]
    [ "${__l_kid}" = "${trial_id}" ]
}

@test "launch wires a call edge from the parent frame to the child" {
    knit_register "ctrial" _l_ctrial_fn "Trial."
    knit_with_table "ctrials"
    _l_ctrial_fn() { :; }
    knit_done

    knit_register "cdriver" _l_cdriver_fn "Driver."
    knit_with_table "cdrivers"
    _l_cdriver_fn() {
        local kid
        _knit_search_launch kid ctrial
    }
    knit_done

    _knit_invoke_command "cdriver"

    local driver_id trial_id
    driver_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM cdrivers;")
    trial_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM ctrials;")
    [ -n "${driver_id}" ]
    [ -n "${trial_id}" ]
    [ "${driver_id}" != "${trial_id}" ]
    # The child's call edge names the launching parent frame.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT source_id,source_name FROM __provenance__ WHERE target_id='${trial_id}';")" \
        = "${driver_id}|cdriver" ]
}

# ---------- a line carrying "--" is forwarded verbatim ----------

@test "launch forwards a line with -- extra arguments verbatim to the target" {
    knit_register "etrial" _l_etrial_fn "Trial with extras."
    knit_with_table "etrials"
    knit_with_extra "Extra arguments."
    _l_etrial_fn() {
        local args=("$@")
        local ei
        ei=$(knit_extra_index "${args[@]}")
        __l_extras="${args[*]:ei}"
    }
    knit_done

    knit_register "edriver" _l_edriver_fn "Driver."
    knit_with_table "edrivers"
    _l_edriver_fn() {
        local kid
        _knit_search_launch kid etrial -- alpha beta
    }
    knit_done

    _knit_invoke_command "edriver"

    # The downstream dispatcher-shaped line (target plus "-- args") reached the
    # target unchanged: the engine is opaque to it.
    [ "${__l_extras}" = "alpha beta" ]
    [ -n "$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM etrials;")" ]
}

# ---------- a root launch (no in-process parent) ----------

@test "launch at the top level records the child with an empty-parent edge" {
    knit_register "rtrial" _l_rtrial_fn "Root trial."
    knit_with_table "rtrials"
    _l_rtrial_fn() { :; }
    knit_done

    local kid
    _knit_search_launch kid rtrial

    local trial_id
    trial_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM rtrials;")
    [ "${kid}" = "${trial_id}" ]
    # No in-process or exported parent: the child edge has empty parent columns.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT source_id,source_name FROM __provenance__ WHERE target_id='${trial_id}';")" \
        = "|" ]
}

# ---------- the downstream exit status is the return value ----------

@test "launch returns the downstream line's exit status on success" {
    knit_register "okcmd" _l_ok_fn "OK."
    _l_ok_fn() { return 0; }
    knit_done

    local kid
    run _knit_search_launch kid okcmd
    [ "$status" -eq 0 ]
}

@test "launch returns the downstream line's non-zero exit status on failure" {
    knit_register "failcmd" _l_fail_fn "Fail."
    _l_fail_fn() { return 7; }
    knit_done

    local kid
    run _knit_search_launch kid failcmd
    [ "$status" -eq 7 ]
}

# ---------- argument guard ----------

@test "launch is fatal with no downstream command line" {
    local kid
    run _knit_search_launch kid
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a downstream command line"* ]]
}
