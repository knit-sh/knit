#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- framework commands are marked builtin ----------

@test "a top-level framework command reports builtin" {
    _knit_command_is_builtin "submit"
    _knit_command_is_builtin "bootstrap"
    _knit_command_is_builtin "setup"
    _knit_command_is_builtin "run"
    _knit_command_is_builtin "metadata"
}

@test "a nested framework command reports builtin" {
    local cmd
    cmd=$(_knit_command_mangle "metadata:store")
    _knit_command_is_builtin "${cmd}"
    cmd=$(_knit_command_mangle "job:show:stdout")
    _knit_command_is_builtin "${cmd}"
}

@test "the spack wrapper is marked builtin" {
    _knit_command_is_builtin "spack"
}

# ---------- user commands are not builtin ----------

@test "a freshly registered user command reports non-builtin" {
    knit_register knit_empty "mycmd" "A user command."
    knit_done
    run _knit_command_is_builtin "mycmd"
    [ "$status" -ne 0 ]
}

@test "knit_register initializes is_builtin to false" {
    knit_register knit_empty "mycmd" "A user command."
    [ "${_KNIT_CMD_mycmd_is_builtin}" = "false" ]
    knit_done
}

@test "_knit_command_is_builtin is false for an unknown command" {
    run _knit_command_is_builtin "does_not_exist"
    [ "$status" -ne 0 ]
}

# ---------- _knit_is_builtin inside a registration ----------

@test "_knit_is_builtin inside a registration marks the current command" {
    knit_register knit_empty "mycmd" "A user command."
    _knit_is_builtin
    [ "${_KNIT_CMD_mycmd_is_builtin}" = "true" ]
    knit_done
    _knit_command_is_builtin "mycmd"
}

# ---------- _knit_is_builtin for enums ----------

@test "a framework enum is marked builtin" {
    _knit_set_find _KNIT_BUILTIN_ENUMS "__scheduler__"
    _knit_set_find _KNIT_BUILTIN_ENUMS "__launcher__"
}

@test "_knit_is_builtin outside a registration marks the last-defined enum" {
    knit_define_enum "mycolor" "red" "green" "blue"
    [ "${_KNIT_LAST_ENUM}" = "mycolor" ]
    _knit_is_builtin
    _knit_set_find _KNIT_BUILTIN_ENUMS "mycolor"
}

@test "a user enum is not marked builtin by default" {
    knit_define_enum "mycolor" "red" "green" "blue"
    run _knit_set_find _KNIT_BUILTIN_ENUMS "mycolor"
    [ "$status" -ne 0 ]
}

@test "_knit_is_builtin is fatal with no command and no enum" {
    _KNIT_LAST_ENUM=''
    run _knit_is_builtin
    [ "$status" -ne 0 ]
}
