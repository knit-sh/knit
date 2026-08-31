#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
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

@test "_knit_command_mangle folds hyphens to underscores" {
    local result
    result=$(_knit_command_mangle "db-show")
    [ "$result" = "db_show" ]
}

@test "_knit_command_mangle folds hyphens per nested segment" {
    local result
    result=$(_knit_command_mangle "grp:db-show")
    [ "$result" = "grp__1__db_show" ]
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

# ---------- _knit_command_display ----------

@test "_knit_command_display returns the registered spelling of a command" {
    knit_register "db-show" knit_empty "A hyphenated command."
    knit_done
    local result
    result=$(_knit_command_display "db_show")
    [ "$result" = "db-show" ]
}

@test "_knit_command_display rebuilds a nested registered spelling" {
    knit_register "grp" knit_empty "A group."
    knit_done
    knit_register "grp:db-show" knit_empty "A nested hyphenated command."
    knit_done
    local result
    result=$(_knit_command_display "grp__1__db_show")
    [ "$result" = "grp:db-show" ]
}

@test "_knit_command_display returns the underscore name when registered so" {
    knit_register "db_show" knit_empty "An underscore command."
    knit_done
    local result
    result=$(_knit_command_display "db_show")
    [ "$result" = "db_show" ]
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
    _knit_command_get_parents result "aaa:bbb:ccc"
    [ "$result" = "aaa:bbb" ]
}

@test "_knit_command_get_parents returns parent for mangled command" {
    local result
    _knit_command_get_parents result "aaa__1__bbb__1__ccc"
    [ "$result" = "aaa__1__bbb" ]
}

@test "_knit_command_get_parents returns parent for space-separated command" {
    local result
    _knit_command_get_parents result "aaa bbb ccc"
    [ "$result" = "aaa bbb" ]
}

@test "_knit_command_get_parents returns empty for top-level command" {
    local result
    _knit_command_get_parents result "aaa"
    [ -z "$result" ]
}

@test "_knit_command_get_parents handles a last segment containing an underscore" {
    local result
    _knit_command_get_parents result "submit__1__my_job"
    [ "$result" = "submit" ]
    _knit_command_get_parents result "submit:my_job"
    [ "$result" = "submit" ]
}

@test "_knit_command_get_parents handles a last segment starting with an underscore" {
    local result
    _knit_command_get_parents result "wgrp__1___leaf"
    [ "$result" = "wgrp" ]
}

@test "_knit_command_get_parents handles a last segment containing a 1" {
    local result
    _knit_command_get_parents result "run__1__app1"
    [ "$result" = "run" ]
}

# ---------- _knit_command_get_last ----------

@test "_knit_command_get_last returns last part for colon-separated command" {
    local result
    _knit_command_get_last result "aaa:bbb:ccc"
    [ "$result" = "ccc" ]
}

@test "_knit_command_get_last returns last part for mangled command" {
    local result
    _knit_command_get_last result "aaa__1__bbb__1__ccc"
    [ "$result" = "ccc" ]
}

@test "_knit_command_get_last returns entire string for single-level command" {
    local result
    _knit_command_get_last result "aaa"
    [ "$result" = "aaa" ]
}

@test "_knit_command_get_last handles a last segment containing an underscore" {
    local result
    _knit_command_get_last result "submit__1__my_job"
    [ "$result" = "my_job" ]
    _knit_command_get_last result "submit:my_job"
    [ "$result" = "my_job" ]
}

# ---------- _knit_param_description / _knit_param_default / _knit_param_type ----------

@test "_knit_param_description returns stored description" {
    knit_register "pd_cmd" knit_empty "Test."
    knit_with_optional "value:string" "default_val" "My description."
    knit_done
    local result
    _knit_param_description result "pd_cmd" "value"
    [ "$result" = "My description." ]
}

@test "_knit_param_default returns stored default value" {
    knit_register "pdef_cmd" knit_empty "Test."
    knit_with_optional "count:integer" "42" "A count."
    knit_done
    local result
    _knit_param_default result "pdef_cmd" "count"
    [ "$result" = "42" ]
}

@test "_knit_param_type returns stored type" {
    knit_register "pt_cmd" knit_empty "Test."
    knit_with_required "count:integer" "A count."
    knit_done
    local result
    _knit_param_type result "pt_cmd" "count"
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

