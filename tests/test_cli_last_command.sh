#!/usr/bin/env bats

# KNIT_LAST_COMMAND_UUID / KNIT_LAST_COMMAND_TABLE: public handles on the row the
# most recent command recorded in this process. Set only when a data row is
# written (a declared table); untouched by a table-less (edge-only) command,
# disabled recording, or an unbootstrapped experiment.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    _KNIT_RECORDING_SUPPRESSED=""
    KNIT_LAST_COMMAND_UUID=""
    KNIT_LAST_COMMAND_TABLE=""
    _knit_prov_create_table
}

teardown() {
    knit_test_db_teardown
}

@test "a recorded command sets the handle to its row id and table" {
    knit_register "lccmd" knit_empty "A recorded command."
    knit_with_table "lctable"
    knit_done

    _knit_invoke_command "lccmd"

    local recorded
    recorded=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM lctable;")
    [ -n "${recorded}" ]
    [ "${KNIT_LAST_COMMAND_UUID}" = "${recorded}" ]
    [ "${KNIT_LAST_COMMAND_TABLE}" = "lctable" ]
}

@test "a table-less (edge-only) command leaves the handle untouched" {
    KNIT_LAST_COMMAND_UUID="sentinel-uuid"
    KNIT_LAST_COMMAND_TABLE="sentinel-table"

    # No knit_with_table: this command records a provenance edge but no data row.
    knit_register "lcedge" knit_empty "An edge-only command."
    knit_done

    _knit_invoke_command "lcedge"

    [ "${KNIT_LAST_COMMAND_UUID}" = "sentinel-uuid" ]
    [ "${KNIT_LAST_COMMAND_TABLE}" = "sentinel-table" ]
}

@test "the handle names the most recent of two recorded commands" {
    knit_register "lcone" knit_empty "First."
    knit_with_table "lcone_rows"
    knit_done
    knit_register "lctwo" knit_empty "Second."
    knit_with_table "lctwo_rows"
    knit_done

    _knit_invoke_command "lcone"
    _knit_invoke_command "lctwo"

    [ "${KNIT_LAST_COMMAND_TABLE}" = "lctwo_rows" ]
    local recorded
    recorded=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM lctwo_rows;")
    [ "${KNIT_LAST_COMMAND_UUID}" = "${recorded}" ]
}

@test "disabled recording leaves the handle untouched" {
    KNIT_LAST_COMMAND_UUID="sentinel-uuid"
    KNIT_LAST_COMMAND_TABLE="sentinel-table"

    knit_register "lcdisabled" knit_empty "A recorded command."
    knit_with_table "lcdisabled_rows"
    knit_done

    KNIT_DISABLE_RECORDING=true _knit_invoke_command "lcdisabled"

    [ "${KNIT_LAST_COMMAND_UUID}" = "sentinel-uuid" ]
    [ "${KNIT_LAST_COMMAND_TABLE}" = "sentinel-table" ]
}

@test "an unbootstrapped experiment leaves the handle untouched" {
    KNIT_LAST_COMMAND_UUID="sentinel-uuid"
    KNIT_LAST_COMMAND_TABLE="sentinel-table"

    knit_register "lcunboot" knit_empty "A recorded command."
    knit_with_table "lcunboot_rows"
    knit_done

    # A full invocation fatals on the usable-before-bootstrap guard before the
    # record path; drive _knit_record_invocation directly to reach its own
    # bootstrap guard, which short-circuits before touching the handle.
    _KNIT_IS_BOOTSTRAPPED="" _KNIT_PREFIX="/nonexistent/.knit" \
        _knit_record_invocation "lcunboot"

    [ "${KNIT_LAST_COMMAND_UUID}" = "sentinel-uuid" ]
    [ "${KNIT_LAST_COMMAND_TABLE}" = "sentinel-table" ]
}
