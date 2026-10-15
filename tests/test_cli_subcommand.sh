#!/usr/bin/env bats

# Tests for the public dispatcher subcommand API (src/cli.sh, M10/G13):
# knit_resolve_subcommand, knit_check_subcommand_exists,
# knit_ensure_subcommand_exists, and knit_check_subcommand_args, plus a
# regression check that the invoker still resolves commands unchanged.

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- knit_resolve_subcommand ----------

@test "resolve_subcommand resolves a nested command and its token count" {
    local cmd consumed
    knit_resolve_subcommand cmd consumed metadata store
    [ "${cmd}" = "metadata__1__store" ]
    [ "${consumed}" -eq 2 ]
}

@test "resolve_subcommand resolves a single root command" {
    local cmd consumed
    knit_resolve_subcommand cmd consumed bootstrap
    [ "${cmd}" = "bootstrap" ]
    [ "${consumed}" -eq 1 ]
}

@test "resolve_subcommand stops consuming at the first option token" {
    local cmd consumed
    knit_resolve_subcommand cmd consumed metadata store --key x --value y
    [ "${cmd}" = "metadata__1__store" ]
    [ "${consumed}" -eq 2 ]
}

@test "resolve_subcommand resolves a wrapper to itself without consuming its args" {
    knit_register_wrapper "mywrap" knit_empty "A wrapper."
    knit_done
    local cmd consumed
    knit_resolve_subcommand cmd consumed mywrap install zlib
    [ "${cmd}" = "mywrap" ]
    [ "${consumed}" -eq 1 ]
}

@test "resolve_subcommand is fatal on an unknown command" {
    run knit_resolve_subcommand cmd consumed no-such-cmd
    [ "$status" -ne 0 ]
    [[ "$output" == *'Unknown command "no-such-cmd"'* ]]
}

# ---------- knit_check_subcommand_exists ----------

@test "check_subcommand_exists is true for a known command and false otherwise" {
    knit_check_subcommand_exists metadata store
    ! knit_check_subcommand_exists totally bogus
}

@test "check_subcommand_exists runs lazy discovery as a side effect" {
    # metadata's subcommands are registered lazily, so metadata:store is unknown
    # until something resolves it.
    ! _knit_set_find _KNIT_COMMANDS "metadata__1__store"
    knit_check_subcommand_exists metadata store
    _knit_set_find _KNIT_COMMANDS "metadata__1__store"
}

# ---------- knit_ensure_subcommand_exists ----------

@test "ensure_subcommand_exists succeeds for a known command" {
    knit_ensure_subcommand_exists metadata store
}

@test "ensure_subcommand_exists is fatal for an unknown command" {
    run knit_ensure_subcommand_exists frobnicate widgets
    [ "$status" -ne 0 ]
    [[ "$output" == *'Unknown command "frobnicate widgets"'* ]]
}

# ---------- knit_check_subcommand_args ----------

@test "check_subcommand_args accepts a valid dispatched invocation" {
    knit_check_subcommand_args metadata store --key k --value v
}

@test "check_subcommand_args is fatal on a missing required option" {
    run knit_check_subcommand_args metadata store --key k
    [ "$status" -ne 0 ]
    [[ "$output" == *'requires a --value option'* ]]
}

@test "check_subcommand_args is fatal on an unexpected option" {
    run knit_check_subcommand_args metadata store --key k --value v --bogus z
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unexpected"* ]]
}

@test "check_subcommand_args short-circuits a wrapper target" {
    knit_register_wrapper "mywrap" knit_empty "A wrapper."
    knit_done
    knit_check_subcommand_args mywrap install zlib
}

@test "check_subcommand_args short-circuits a --help request" {
    knit_check_subcommand_args metadata store --help
}

@test "check_subcommand_args is fatal on an unknown command" {
    run knit_check_subcommand_args nope --flag
    [ "$status" -ne 0 ]
    [[ "$output" == *'Unknown command "nope"'* ]]
}

# ---------- invoker regression ----------

@test "the invoker still resolves a nested command and reports an unknown one" {
    run knit metadata store --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]

    run knit no-such-cmd
    [ "$status" -ne 0 ]
    [[ "$output" == *'Unknown command "no-such-cmd"'* ]]
}
