#!/usr/bin/env bats

setup() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi

    source knit.sh

    # Override the sqlite executable and database path for testing
    _KNIT_SQLITE_EXE="sqlite3"
    _KNIT_DATABASE="$(mktemp --suffix=.db)"

    # Satisfy the bootstrap check — tests in this file work with a live DB
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    rm -f "${_KNIT_DATABASE}"
    _KNIT_IS_BOOTSTRAPPED=""
}

# ---------- knit_empty ----------

@test "knit_empty returns 0" {
    knit_empty
}

# ---------- _knit_command_mangle ----------

@test "_knit_command_mangle converts colons to __1__" {
    local result
    result=$(_knit_command_mangle "foo:bar:baz")
    [ "$result" = "foo__1__bar__1__baz" ]
}

@test "_knit_command_mangle converts spaces to __1__" {
    local result
    result=$(_knit_command_mangle "foo bar baz")
    [ "$result" = "foo__1__bar__1__baz" ]
}

@test "_knit_command_mangle leaves single word unchanged" {
    local result
    result=$(_knit_command_mangle "foo")
    [ "$result" = "foo" ]
}

# ---------- _knit_command_demangle ----------

@test "_knit_command_demangle converts __1__ back to colons" {
    local result
    result=$(_knit_command_demangle "foo__1__bar__1__baz")
    [ "$result" = "foo:bar:baz" ]
}

@test "_knit_command_demangle leaves single word unchanged" {
    local result
    result=$(_knit_command_demangle "foo")
    [ "$result" = "foo" ]
}

# ---------- _knit_command_with_space ----------

@test "_knit_command_with_space converts __1__ to spaces" {
    local result
    result=$(_knit_command_with_space "foo__1__bar__1__baz")
    [ "$result" = "foo bar baz" ]
}

@test "_knit_command_with_space converts colons to spaces" {
    local result
    result=$(_knit_command_with_space "foo:bar:baz")
    [ "$result" = "foo bar baz" ]
}

# ---------- _knit_name_normalize ----------

@test "_knit_name_normalize converts hyphens to underscores" {
    local result
    result=$(_knit_name_normalize "my-param-name")
    [ "$result" = "my_param_name" ]
}

@test "_knit_name_normalize leaves underscores unchanged" {
    local result
    result=$(_knit_name_normalize "my_param_name")
    [ "$result" = "my_param_name" ]
}

# ---------- _knit_name_is_valid ----------

@test "_knit_name_is_valid accepts valid names" {
    _knit_name_is_valid "abc"
    _knit_name_is_valid "abc123"
    _knit_name_is_valid "abc-def"
    _knit_name_is_valid "abc_def"
    _knit_name_is_valid "A1_b-c"
    _knit_name_is_valid "_private"
}

@test "_knit_name_is_valid rejects empty string" {
    run _knit_name_is_valid ""
    [ "$status" -eq 1 ]
}

@test "_knit_name_is_valid rejects names with spaces" {
    run _knit_name_is_valid "abc def"
    [ "$status" -eq 1 ]
}

@test "_knit_name_is_valid rejects names with colons" {
    run _knit_name_is_valid "abc:def"
    [ "$status" -eq 1 ]
}

@test "_knit_name_is_valid rejects reserved constraint keywords" {
    run _knit_name_is_valid "true";  [ "$status" -eq 1 ]
    run _knit_name_is_valid "false"; [ "$status" -eq 1 ]
    run _knit_name_is_valid "null";  [ "$status" -eq 1 ]
    run _knit_name_is_valid "and";   [ "$status" -eq 1 ]
    run _knit_name_is_valid "or";    [ "$status" -eq 1 ]
    run _knit_name_is_valid "not";   [ "$status" -eq 1 ]
}

# ---------- _knit_command_get_parents ----------

@test "_knit_command_get_parents returns parent for colon-separated command" {
    local result
    result=$(_knit_command_get_parents "aaa:bbb:ccc")
    [ "$result" = "aaa:bbb" ]
}

@test "_knit_command_get_parents returns parent for mangled command" {
    local result
    result=$(_knit_command_get_parents "aaa__1__bbb__1__ccc")
    [ "$result" = "aaa__1__bbb" ]
}

@test "_knit_command_get_parents returns parent for space-separated command" {
    local result
    result=$(_knit_command_get_parents "aaa bbb ccc")
    [ "$result" = "aaa bbb" ]
}

@test "_knit_command_get_parents returns empty for top-level command" {
    local result
    result=$(_knit_command_get_parents "aaa")
    [ -z "$result" ]
}

# ---------- _knit_command_get_last ----------

@test "_knit_command_get_last returns last part for colon-separated command" {
    local result
    result=$(_knit_command_get_last "aaa:bbb:ccc")
    [ "$result" = "ccc" ]
}

@test "_knit_command_get_last returns last part for mangled command" {
    local result
    result=$(_knit_command_get_last "aaa__1__bbb__1__ccc")
    [ "$result" = "ccc" ]
}

@test "_knit_command_get_last returns entire string for single-level command" {
    local result
    result=$(_knit_command_get_last "aaa")
    [ "$result" = "aaa" ]
}

# ---------- _knit_param_description_var / _knit_param_default_var / _knit_param_type_var ----------

@test "_knit_param_description_var returns expected variable name" {
    local result
    result=$(_knit_param_description_var "mycmd" "myparam")
    [ "$result" = "_KNIT_CMD_mycmd_2_myparam_description" ]
}

@test "_knit_param_default_var returns expected variable name" {
    local result
    result=$(_knit_param_default_var "mycmd" "myparam")
    [ "$result" = "_KNIT_CMD_mycmd_2_myparam_default" ]
}

@test "_knit_param_type_var returns expected variable name" {
    local result
    result=$(_knit_param_type_var "mycmd" "myparam")
    [ "$result" = "_KNIT_CMD_mycmd_2_myparam_type" ]
}

# ---------- _knit_param_description / _knit_param_default / _knit_param_type ----------

@test "_knit_param_description returns stored description" {
    knit_register knit_empty "pd_cmd" "Test."
    knit_with_optional "value:string" "default_val" "My description."
    knit_done
    local result
    result=$(_knit_param_description "pd_cmd" "value")
    [ "$result" = "My description." ]
}

@test "_knit_param_default returns stored default value" {
    knit_register knit_empty "pdef_cmd" "Test."
    knit_with_optional "count:integer" "42" "A count."
    knit_done
    local result
    result=$(_knit_param_default "pdef_cmd" "count")
    [ "$result" = "42" ]
}

@test "_knit_param_type returns stored type" {
    knit_register knit_empty "pt_cmd" "Test."
    knit_with_required "count:integer" "A count."
    knit_done
    local result
    result=$(_knit_param_type "pt_cmd" "count")
    [ "$result" = "integer" ]
}

# ---------- _knit_resolve_default ----------

@test "_knit_resolve_default returns a plain default unchanged" {
    local result
    result=$(_knit_resolve_default "hello")
    [ "$result" = "hello" ]
}

@test "_knit_resolve_default resolves ENV[NAME] to the environment variable" {
    export _KNIT_TEST_ENV_DEFAULT="from-env"
    local result
    result=$(_knit_resolve_default "ENV[_KNIT_TEST_ENV_DEFAULT]")
    [ "$result" = "from-env" ]
    unset _KNIT_TEST_ENV_DEFAULT
}

@test "_knit_resolve_default yields empty string when the variable is unset" {
    unset _KNIT_TEST_ENV_MISSING
    local result
    result=$(_knit_resolve_default "ENV[_KNIT_TEST_ENV_MISSING]")
    [ -z "$result" ]
}

@test "_knit_resolve_default leaves a malformed ENV[...] token literal" {
    local result
    # A space is not valid in a shell variable name, so this is not a reference.
    result=$(_knit_resolve_default "ENV[not a name]")
    [ "$result" = "ENV[not a name]" ]
}

@test "_knit_resolve_default does not treat a substring ENV[...] as a reference" {
    export _KNIT_TEST_ENV_DEFAULT="from-env"
    local result
    result=$(_knit_resolve_default "prefix-ENV[_KNIT_TEST_ENV_DEFAULT]")
    [ "$result" = "prefix-ENV[_KNIT_TEST_ENV_DEFAULT]" ]
    unset _KNIT_TEST_ENV_DEFAULT
}

