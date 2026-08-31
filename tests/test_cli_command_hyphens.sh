#!/usr/bin/env bats

# Feature: hyphens in command names (display). A command registered with a
# hyphen keeps that spelling everywhere it is shown to a human ("--help",
# "describe"), while its identity (variable stems, "@with_table" table name, and
# provenance node label) stays the canonical underscore form.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    _KNIT_RECORDING_SUPPRESSED=""
    _knit_prov_create_table
}

teardown() {
    knit_test_db_teardown
}

# ---------- --help display ----------

@test "--help shows the registered hyphen spelling in the usage line" {
    knit_register "db-show" knit_empty "Show the database."
    knit_done

    run _knit_print_command_usage "db-show"
    [ "$status" -eq 0 ]
    [[ "$output" == *"db-show [OPTIONS]"* ]]
    [[ "$output" != *"db_show"* ]]
}

@test "--help shows a nested hyphen spelling in the usage line" {
    knit_register "grp" knit_empty "A group."
    knit_done
    knit_register "grp:db-show" knit_empty "Show the database."
    knit_done

    run _knit_print_command_usage "grp" "db-show"
    [ "$status" -eq 0 ]
    [[ "$output" == *"grp db-show [OPTIONS]"* ]]
}

@test "--help lists a hyphenated subcommand with its registered spelling" {
    knit_register "grp" knit_empty "A group."
    knit_done
    knit_register "grp:db-show" knit_empty "Show the database."
    knit_done

    run _knit_print_command_usage "grp"
    [ "$status" -eq 0 ]
    [[ "$output" == *"db-show"* ]]
}

# ---------- describe display ----------

@test "describe (default) shows the registered hyphen spelling" {
    knit_register "db-show" knit_empty "Show the database."
    knit_done

    run _knit_describe --format default
    [ "$status" -eq 0 ]
    [[ "$output" == *"db-show"* ]]
}

@test "describe (json) shows the registered hyphen spelling in the name" {
    knit_register "db-show" knit_empty "Show the database."
    knit_done

    run _knit_describe --format json
    [ "$status" -eq 0 ]
    [[ "$output" == *"\"db-show\""* ]]
}

# ---------- identity stays canonical ----------

@test "a hyphenated command's table keeps the underscore identity" {
    knit_register "db-show" knit_empty "Show the database."
    knit_with_table
    knit_done

    local shown hyphen
    shown=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='db_show';")
    hyphen=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='db-show';")
    [ "$shown" -eq 1 ]
    [ "$hyphen" -eq 0 ]
}

@test "a hyphenated command records a canonical provenance target_name" {
    knit_register "db-show" _dbshow_fn "Show the database."
    knit_with_table
    _dbshow_fn() { :; }
    knit_done

    _knit_invoke_command "db-show"

    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT DISTINCT target_name FROM ${_KNIT_PROV_TABLE};")
    [[ "${names}" == *"db_show"* ]]
    [[ "${names}" != *"db-show"* ]]
}
