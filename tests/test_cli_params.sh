#!/usr/bin/env bats

setup() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi

    source knit.sh

    # Override the sqlite executable and database path for testing
    __KNIT_SQLITE_EXE="sqlite3"
    __KNIT_DATABASE="$(mktemp --suffix=.db)"

    # Satisfy the bootstrap check — tests in this file work with a live DB
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    rm -f "${__KNIT_DATABASE}"
    _KNIT_IS_BOOTSTRAPPED=""
}

@test "finding an option that exists" {
    local args=("--abc" "ABC" "--def" "DEF" "--ghi" "GHI")
    run knit_get_parameter "abc" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "ABC" ]
    run knit_get_parameter "def" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "DEF" ]
    run knit_get_parameter "ghi" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "GHI" ]
}

@test "finding an option that does not exist" {
    local args=("--abc" "ABC" "--def" "DEF" "--ghi" "GHI")
    run knit_get_parameter "jkl" "${args[@]}"
    [ "$status" -eq 1 ]
}

@test "knit_get_parameter reads the --name=value form" {
    local args=("--abc=ABC" "--def" "DEF")
    run knit_get_parameter "abc" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "ABC" ]
    run knit_get_parameter "def" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "DEF" ]
}

@test "knit_get_parameter --name=value splits only on the first equals sign" {
    local args=("--abc=a=b=c")
    run knit_get_parameter "abc" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "a=b=c" ]
}

@test "knit_get_parameter --name= yields an empty value" {
    local args=("--abc=")
    run knit_get_parameter "abc" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "knit_get_parameter does not match a value that looks like a name" {
    # "frame-color" here is the value of --x, not the parameter --frame-color.
    local args=("--x" "frame-color")
    run knit_get_parameter "frame-color" "${args[@]}"
    [ "$status" -eq 1 ]
}

# ---------- knit_with_required type annotations ----------

@test "knit_with_required accepts name:type syntax" {
    knit_register knit_empty "test_cmd_1" "A test command."
    knit_with_required "count:integer" "A count parameter."
    knit_done
}

@test "knit_with_required rejects missing type" {
    knit_register knit_empty "test_cmd_2" "A test command."
    run knit_with_required "name" "A name parameter."
    [ "$status" -eq 1 ]
}

@test "knit_with_required rejects unknown type" {
    knit_register knit_empty "test_cmd_3" "A test command."
    run knit_with_required "count:nosuchtype" "A count parameter."
    [ "$status" -eq 1 ]
}

@test "knit_with_required accepts alias types" {
    knit_register knit_empty "test_cmd_4" "A test command."
    knit_with_required "count:int" "A count parameter."
    knit_done
}

@test "knit_with_required accepts enum types" {
    knit_define_enum "color" "red" "green" "blue"
    knit_register knit_empty "test_cmd_5" "A test command."
    knit_with_required "shade:color" "A color parameter."
    knit_done
}

# ---------- knit_with_optional type annotations ----------

@test "knit_with_optional accepts name:type syntax" {
    knit_register knit_empty "test_cmd_6" "A test command."
    knit_with_optional "count:integer" "10" "A count parameter."
    knit_done
}

@test "knit_with_optional rejects missing type" {
    knit_register knit_empty "test_cmd_7" "A test command."
    run knit_with_optional "name" "world" "A name parameter."
    [ "$status" -eq 1 ]
}

@test "knit_with_optional rejects unknown type" {
    knit_register knit_empty "test_cmd_8" "A test command."
    run knit_with_optional "count:nosuchtype" "10" "A count parameter."
    [ "$status" -eq 1 ]
}

# ---------- knit_with_output type annotations ----------

@test "knit_with_output accepts name:type syntax" {
    knit_register knit_empty "out_cmd_1" "A test command."
    knit_with_output "result:integer" "0" "The result."
    knit_done
}

@test "knit_with_output rejects missing type" {
    knit_register knit_empty "out_cmd_2" "A test command."
    run knit_with_output "result" "0" "The result."
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_output rejects unknown type" {
    knit_register knit_empty "out_cmd_3" "A test command."
    run knit_with_output "result:nosuchtype" "0" "The result."
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_output fails outside of knit_register" {
    run knit_with_output "result:integer" "0" "The result."
    [ "$status" -eq 1 ]
}

@test "knit_with_output rejects invalid output name" {
    knit_register knit_empty "out_cmd_4" "A test command."
    run knit_with_output "invalid name:string" "x" "Bad name."
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_output rejects duplicate output name" {
    knit_register knit_empty "out_cmd_5" "A test command."
    knit_with_output "result:integer" "0" "First declaration."
    run knit_with_output "result:integer" "1" "Duplicate."
    [ "$status" -eq 1 ]
    knit_done
}

# ---------- knit_output ----------

@test "knit_output fails outside of registered command" {
    run knit_output "result" "42"
    [ "$status" -eq 1 ]
}

@test "knit_output fails for undeclared output name" {
    ko_fail_fn() { knit_output "undeclared" "1"; }
    knit_register ko_fail_fn "ko_fail_cmd" "Test."
    knit_with_output "result:integer" "0" "The result."
    knit_done
    run _knit_invoke_command "ko_fail_cmd"
    [ "$status" -eq 1 ]
}

@test "knit_output fails on type mismatch" {
    ko_type_fn() { knit_output "result" "not_an_integer"; }
    knit_register ko_type_fn "ko_type_cmd" "Test."
    knit_with_output "result:integer" "0" "The result."
    knit_done
    run _knit_invoke_command "ko_type_cmd"
    [ "$status" -eq 1 ]
}

@test "knit_output sets value in output array" {
    ko_set_fn() { knit_output "result" "42"; }
    knit_register ko_set_fn "ko_set_cmd" "Test."
    knit_with_output "result:integer" "0" "The result."
    knit_done
    _knit_invoke_command "ko_set_cmd"
    [ "${_KNIT_CMD_ko_set_cmd_output_value[result]}" = "42" ]
}

@test "knit_output normalizes hyphen to underscore in name" {
    ko_hyp_fn() { knit_output "my-result" "7"; }
    knit_register ko_hyp_fn "ko_hyp_cmd" "Test."
    knit_with_output "my-result:integer" "0" "The result."
    knit_done
    _knit_invoke_command "ko_hyp_cmd"
    [ "${_KNIT_CMD_ko_hyp_cmd_output_value[my_result]}" = "7" ]
}

@test "knit_output nested invocation preserves outer context" {
    ko_inner_fn() { knit_output "inner_out" "inner_val"; }
    knit_register ko_inner_fn "ko_inner_cmd" "Test."
    knit_with_output "inner_out:string" "" "Inner output."
    knit_done
    ko_outer_fn() {
        _knit_invoke_command "ko_inner_cmd"
        knit_output "outer_out" "outer_val"
    }
    knit_register ko_outer_fn "ko_outer_cmd" "Test."
    knit_with_output "outer_out:string" "" "Outer output."
    knit_done
    _knit_invoke_command "ko_outer_cmd"
    [ "${_KNIT_CMD_ko_inner_cmd_output_value[inner_out]}" = "inner_val" ]
    [ "${_KNIT_CMD_ko_outer_cmd_output_value[outer_out]}" = "outer_val" ]
}

# ---------- __knit_output_description_var / __knit_output_default_var / __knit_output_type_var ----------

@test "__knit_output_description_var returns expected variable name" {
    local result
    result=$(__knit_output_description_var "mycmd" "myoutput")
    [ "$result" = "_KNIT_CMD_mycmd_3_myoutput_description" ]
}

@test "__knit_output_default_var returns expected variable name" {
    local result
    result=$(__knit_output_default_var "mycmd" "myoutput")
    [ "$result" = "_KNIT_CMD_mycmd_3_myoutput_default" ]
}

@test "__knit_output_type_var returns expected variable name" {
    local result
    result=$(__knit_output_type_var "mycmd" "myoutput")
    [ "$result" = "_KNIT_CMD_mycmd_3_myoutput_type" ]
}

# ---------- __knit_output_description / __knit_output_default / __knit_output_type ----------

@test "__knit_output_description returns stored description" {
    knit_register knit_empty "od_cmd" "Test."
    knit_with_output "score:real" "0.0" "The score."
    knit_done
    local result
    result=$(__knit_output_description "od_cmd" "score")
    [ "$result" = "The score." ]
}

@test "__knit_output_default returns stored default value" {
    knit_register knit_empty "odef_cmd" "Test."
    knit_with_output "count:integer" "42" "A count."
    knit_done
    local result
    result=$(__knit_output_default "odef_cmd" "count")
    [ "$result" = "42" ]
}

@test "__knit_output_type returns stored type" {
    knit_register knit_empty "ot_cmd" "Test."
    knit_with_output "count:integer" "0" "A count."
    knit_done
    local result
    result=$(__knit_output_type "ot_cmd" "count")
    [ "$result" = "integer" ]
}

