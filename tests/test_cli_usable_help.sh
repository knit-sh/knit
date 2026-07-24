#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # A small command tree used by the help-filter tests:
    #   ubbh_pub          (usable)   with subcommands:
    #       ubbh_pub:sub  (usable)
    #       ubbh_pub:priv (not usable)
    #   ubbh_secret       (not usable, top-level)
    knit_register knit_empty "ubbh_pub" "A public command."
    knit_usable_before_bootstrap
    knit_done
    knit_register knit_empty "ubbh_pub:sub" "A public subcommand."
    knit_usable_before_bootstrap
    knit_done
    knit_register knit_empty "ubbh_pub:priv" "A private subcommand."
    knit_done
    knit_register knit_empty "ubbh_secret" "A private command."
    knit_done
}

teardown() {
    knit_test_db_teardown
}

_set_not_bootstrapped() {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/knit_ubbh_$$"
}

_set_bootstrapped() {
    _KNIT_IS_BOOTSTRAPPED="1"
}

# ---------- root --help before bootstrap ----------

@test "before bootstrap root --help omits not-usable commands" {
    _set_not_bootstrapped
    run _knit_print_command_usage "__main__"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ubbh_pub"* ]]
    [[ "$output" != *"ubbh_secret"* ]]
}

@test "before bootstrap root --help still lists usable builtins" {
    _set_not_bootstrapped
    run _knit_print_command_usage "__main__"
    [[ "$output" == *"bootstrap"* ]]
    [[ "$output" == *"describe"* ]]
    [[ "$output" == *"profile"* ]]
}

@test "before bootstrap root --help omits not-usable builtins" {
    _set_not_bootstrapped
    run _knit_print_command_usage "__main__"
    [[ "$output" != *"submit"* ]]
    [[ "$output" != *"metadata"* ]]
}

@test "before bootstrap bootstrap is the first subcommand listed" {
    _set_not_bootstrapped
    run _knit_print_command_usage "__main__"
    # The first command line after the "Subcommands" header names bootstrap.
    local first
    first=$(printf '%s\n' "$output" \
        | awk '/^Subcommands$/{getline; getline; print; exit}')
    [[ "${first}" == *"bootstrap"* ]]
}

# ---------- nested --help before bootstrap ----------

@test "before bootstrap a usable parent lists only its usable children" {
    _set_not_bootstrapped
    run _knit_print_command_usage "ubbh_pub"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sub"* ]]
    [[ "$output" != *"priv"* ]]
}

@test "a not-usable command's --help still renders before bootstrap" {
    _set_not_bootstrapped
    run _knit_print_command_usage "ubbh_secret"
    [ "$status" -eq 0 ]
    [[ "$output" == *"A private command."* ]]
}

# ---------- --help after bootstrap ----------

@test "after bootstrap root --help lists all non-hidden commands" {
    _set_bootstrapped
    run _knit_print_command_usage "__main__"
    [[ "$output" == *"ubbh_pub"* ]]
    [[ "$output" == *"ubbh_secret"* ]]
    [[ "$output" == *"submit"* ]]
}

@test "after bootstrap a parent lists all its non-hidden children" {
    _set_bootstrapped
    run _knit_print_command_usage "ubbh_pub"
    [[ "$output" == *"sub"* ]]
    [[ "$output" == *"priv"* ]]
}

# ---------- hidden commands never shown ----------

@test "hidden commands are never listed regardless of bootstrap state" {
    knit_register knit_empty "ubbh_hidden" "A hidden command."
    knit_hidden
    knit_done
    _set_bootstrapped
    run _knit_print_command_usage "__main__"
    [[ "$output" != *"ubbh_hidden"* ]]
    _set_not_bootstrapped
    run _knit_print_command_usage "__main__"
    [[ "$output" != *"ubbh_hidden"* ]]
}
