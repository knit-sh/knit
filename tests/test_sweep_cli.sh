#!/usr/bin/env bats
#
# M1 tests for the `knit sweep` command skeleton: registration, "--help", the
# control-option surface and its validation, the downstream split, and the fixed
# "sweeps" table column set.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

_columns_of() {
    sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('$1');" | cut -d'|' -f2
}

@test "sweep is a registered command" {
    _knit_set_find _KNIT_COMMANDS "sweep"
}

@test "sweep --help renders the control-option surface" {
    run _knit_invoke_command "sweep" "--help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--group"* ]]
    [[ "$output" == *"--on-failure"* ]]
    [[ "$output" == *"--parallel"* ]]
    [[ "$output" == *"--passthrough"* ]]
    [[ "$output" == *"--fill"* ]]
    [[ "$output" == *"--dry-run"* ]]
    # The dispatcher placeholder is shown in the usage line.
    [[ "$output" == *"downstream"* ]]
}

@test "sweep requires a downstream command after --" {
    run _knit_invoke_command "sweep" "--group" "g"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a downstream command"* ]]
}

@test "sweep rejects a bad --on-failure value" {
    run _knit_invoke_command "sweep" "--on-failure" "bogus" "--" "render"
    [ "$status" -ne 0 ]
    [[ "$output" == *"continue"* ]]
    [[ "$output" == *"stop"* ]]
}

@test "sweep rejects a bad --fill value" {
    run _knit_invoke_command "sweep" "--fill" "bogus" "--" "render"
    [ "$status" -ne 0 ]
    [[ "$output" == *"default"* ]]
    [[ "$output" == *"sweep"* ]]
}

@test "sweep rejects a non-integer --parallel value" {
    run _knit_invoke_command "sweep" "--parallel" "notanint" "--" "render"
    [ "$status" -ne 0 ]
    [[ "$output" == *"integer"* ]]
}

@test "sweep accepts a valid invocation" {
    run _knit_invoke_command "sweep" "--group" "g" "--parallel" "4" \
        "--" "submit" "--nodes" "2" "--" "montecarlo" "--samples" "10"
    [ "$status" -eq 0 ]
}

@test "the downstream split keeps inner -- tokens" {
    local -a down
    _knit_sweep_downstream down \
        "--group" "g" "--parallel" "4" \
        "--" "submit" "--nodes" "2" "--" "montecarlo" "--samples" "10"
    # Everything after the FIRST -- is the downstream, inner -- preserved.
    [ "${down[0]}" = "submit" ]
    [ "${down[1]}" = "--nodes" ]
    [ "${down[2]}" = "2" ]
    [ "${down[3]}" = "--" ]
    [ "${down[4]}" = "montecarlo" ]
    [ "${down[5]}" = "--samples" ]
    [ "${down[6]}" = "10" ]
}

@test "the downstream of a bare command is the command and its args" {
    local -a down
    _knit_sweep_downstream down "--group" "g" "--" "render" "--width" "256"
    [ "${#down[@]}" -eq 3 ]
    [ "${down[0]}" = "render" ]
    [ "${down[1]}" = "--width" ]
    [ "${down[2]}" = "256" ]
}

@test "the sweeps table is created with exactly the fixed columns" {
    _knit_invoke_command "sweep" "--group" "g" "--" "render" "--width" "256"
    local cols
    cols="$(_columns_of sweeps)"
    # The fixed, kind-independent data columns are present.
    [[ "$cols" == *"id"* ]]
    [[ "$cols" == *"group"* ]]
    [[ "$cols" == *"target"* ]]
    [[ "$cols" == *"dispatcher"* ]]
    [[ "$cols" == *"dimensions"* ]]
    [[ "$cols" == *"count"* ]]
    # The control options carry no column (declared --no-record).
    [[ "$cols" != *"on_failure"* ]]
    [[ "$cols" != *"parallel"* ]]
    [[ "$cols" != *"passthrough"* ]]
    [[ "$cols" != *"fill"* ]]
    [[ "$cols" != *"dry_run"* ]]
}
