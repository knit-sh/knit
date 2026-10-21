#!/usr/bin/env bats
#
# Tests for the "--no-record" parameter modifier: a parameter or flag declared
# with it is parsed, validated, and shown in "--help" like any other option, but
# carries no table column and appears in no recorded row.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # A command with one recorded optional ("keep"), one no-record optional
    # ("ctrl", an integer so type validation can be checked), one no-record flag
    # ("loud"), a recorded output ("count"), and a table. The body echoes the
    # values it reads so a test can confirm the no-record options still reach it.
    knit_register "nr_demo" _nr_demo "A command with no-record options."
    knit_with_optional "keep:string" "" "A recorded option."
    knit_with_optional "ctrl:integer" "1" "A control option." --no-record
    knit_with_flag "loud" "A control flag." --no-record
    knit_with_table "nr_demos"
    knit_with_output "count:integer" "0" "A recorded output."
    _nr_demo() {
        knit_output "count" "7"
        printf 'keep=%s ctrl=%s loud=%s\n' \
            "$(knit_get_parameter keep "$@")" \
            "$(knit_get_parameter ctrl "$@")" \
            "$(knit_get_parameter loud "$@")"
    }
    knit_done
}

teardown() {
    knit_test_db_teardown
}

_columns_of() {
    sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('$1');" | cut -d'|' -f2
}

@test "no-record options are shown in --help" {
    run _knit_invoke_command "nr_demo" "--help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--ctrl"* ]]
    [[ "$output" == *"--loud"* ]]
    [[ "$output" == *"--keep"* ]]
}

@test "no-record options still reach the command body" {
    run _knit_invoke_command "nr_demo" "--keep" "k" "--ctrl" "4" "--loud"
    [ "$status" -eq 0 ]
    [[ "$output" == *"keep=k ctrl=4 loud=true"* ]]
}

@test "no-record option still has its type validated" {
    run _knit_invoke_command "nr_demo" "--ctrl" "notanint"
    [ "$status" -ne 0 ]
    [[ "$output" == *"integer"* ]]
}

@test "the table omits no-record columns but keeps recorded ones" {
    _knit_invoke_command "nr_demo" "--keep" "k" "--ctrl" "4" "--loud"
    local cols
    cols="$(_columns_of nr_demos)"
    [[ "$cols" == *"id"* ]]
    [[ "$cols" == *"keep"* ]]
    [[ "$cols" == *"count"* ]]
    [[ "$cols" != *"ctrl"* ]]
    [[ "$cols" != *"loud"* ]]
}

@test "a recorded row carries the recorded columns and no no-record data" {
    _knit_invoke_command "nr_demo" "--keep" "k" "--ctrl" "4" "--loud"
    local keep count
    keep=$(sqlite3 "${_KNIT_DATABASE}" "SELECT keep FROM nr_demos;")
    count=$(sqlite3 "${_KNIT_DATABASE}" "SELECT count FROM nr_demos;")
    [ "$keep" = "k" ]
    [ "$count" = "7" ]
    # Selecting a no-record column must fail: the column does not exist.
    run sqlite3 "${_KNIT_DATABASE}" "SELECT ctrl FROM nr_demos;"
    [ "$status" -ne 0 ]
}
