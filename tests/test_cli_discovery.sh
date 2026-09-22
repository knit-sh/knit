#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- knit_with_subcommand_discovery: marker ----------

@test "knit_with_subcommand_discovery sets the discovery and discovered markers" {
    knit_register "grp" knit_empty "A group."
    knit_with_subcommand_discovery grp_discover
    knit_done
    [ "${_KNIT_CMD_grp_subcommand_discovery}" = "grp_discover" ]
    [ "${_KNIT_CMD_grp_discovered}" = "false" ]
}

@test "knit_with_subcommand_discovery does not require the function to exist yet" {
    # The named function may be defined after the decorator; existence is only
    # checked when it is called.
    knit_register "grp" knit_empty "A group."
    knit_with_subcommand_discovery not_defined_yet
    knit_done
    [ "${_KNIT_CMD_grp_subcommand_discovery}" = "not_defined_yet" ]
}

# ---------- validation ----------

@test "knit_with_subcommand_discovery outside a command is fatal" {
    run knit_with_subcommand_discovery some_fn
    [ "$status" -ne 0 ]
    [[ "$output" == *"after a call to \"knit_register\""* ]]
}

@test "knit_with_subcommand_discovery on a wrapper is fatal" {
    wrap_fn() { :; }
    knit_register_wrapper "wrap" "wrap_fn" "A wrapper."
    run knit_with_subcommand_discovery wrap_discover
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be used with a wrapper command"* ]]
    knit_done
}

@test "knit_with_subcommand_discovery with an empty function name is fatal" {
    knit_register "grp" knit_empty "A group."
    run knit_with_subcommand_discovery ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a function name"* ]]
    knit_done
}

@test "knit_with_subcommand_discovery declared twice is fatal" {
    knit_register "grp" knit_empty "A group."
    knit_with_subcommand_discovery first_discover
    run knit_with_subcommand_discovery second_discover
    [ "$status" -ne 0 ]
    [[ "$output" == *"already has a subcommand discovery function"* ]]
    knit_done
}

# ---------- _knit_ensure_discovered ----------

@test "_knit_ensure_discovered runs the discovery function exactly once" {
    _KNIT_DISC_CALLS=0
    grp_discover() {
        _KNIT_DISC_CALLS=$((_KNIT_DISC_CALLS + 1))
        knit_register "grp:sub" knit_empty "A subcommand."
        knit_done
    }
    knit_register "grp" knit_empty "A group."
    knit_with_subcommand_discovery grp_discover
    knit_done

    _knit_ensure_discovered "grp"
    _knit_ensure_discovered "grp"
    [ "${_KNIT_DISC_CALLS}" -eq 1 ]
    [ "${_KNIT_CMD_grp_discovered}" = "true" ]
    _knit_set_find _KNIT_COMMANDS "grp__1__sub"
}

@test "_knit_ensure_discovered passes the parent display name to the function" {
    _KNIT_DISC_ARG=""
    grp_discover() { _KNIT_DISC_ARG="$1"; }
    knit_register "my-grp" knit_empty "A group."
    knit_with_subcommand_discovery grp_discover
    knit_done

    _knit_ensure_discovered "my_grp"
    [ "${_KNIT_DISC_ARG}" = "my-grp" ]
}

@test "_knit_ensure_discovered is a no-op for a command without a discovery function" {
    knit_register "grp" knit_empty "A group."
    knit_done
    _knit_ensure_discovered "grp"
    [ ! -v _KNIT_CMD_grp_discovered ]
}

@test "_knit_ensure_discovered is a no-op for an unknown command" {
    _knit_ensure_discovered "does_not_exist"
}

@test "_knit_ensure_discovered is fatal when the discovery function is missing" {
    knit_register "grp" knit_empty "A group."
    knit_with_subcommand_discovery not_defined_anywhere
    knit_done
    run _knit_ensure_discovered "grp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not defined"* ]]
}
