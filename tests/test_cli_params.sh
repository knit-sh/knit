#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
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
    knit_register "test_cmd_1" knit_empty "A test command."
    knit_with_required "count:integer" "A count parameter."
    knit_done
}

@test "knit_with_required rejects missing type" {
    knit_register "test_cmd_2" knit_empty "A test command."
    run knit_with_required "name" "A name parameter."
    [ "$status" -eq 1 ]
}

@test "knit_with_required rejects unknown type" {
    knit_register "test_cmd_3" knit_empty "A test command."
    run knit_with_required "count:nosuchtype" "A count parameter."
    [ "$status" -eq 1 ]
}

@test "knit_with_required accepts alias types" {
    knit_register "test_cmd_4" knit_empty "A test command."
    knit_with_required "count:int" "A count parameter."
    knit_done
}

@test "knit_with_required accepts enum types" {
    knit_enum "color" "red" "green" "blue"
    knit_register "test_cmd_5" knit_empty "A test command."
    knit_with_required "shade:color" "A color parameter."
    knit_done
}

# ---------- knit_with_optional type annotations ----------

@test "knit_with_optional accepts name:type syntax" {
    knit_register "test_cmd_6" knit_empty "A test command."
    knit_with_optional "count:integer" "10" "A count parameter."
    knit_done
}

@test "knit_with_optional rejects missing type" {
    knit_register "test_cmd_7" knit_empty "A test command."
    run knit_with_optional "name" "world" "A name parameter."
    [ "$status" -eq 1 ]
}

@test "knit_with_optional rejects unknown type" {
    knit_register "test_cmd_8" knit_empty "A test command."
    run knit_with_optional "count:nosuchtype" "10" "A count parameter."
    [ "$status" -eq 1 ]
}

# ---------- knit_with_output type annotations ----------

@test "knit_with_output accepts name:type syntax" {
    knit_register "out_cmd_1" knit_empty "A test command."
    knit_with_output "result:integer" "0" "The result."
    knit_done
}

@test "knit_with_output rejects missing type" {
    knit_register "out_cmd_2" knit_empty "A test command."
    run knit_with_output "result" "0" "The result."
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_output rejects unknown type" {
    knit_register "out_cmd_3" knit_empty "A test command."
    run knit_with_output "result:nosuchtype" "0" "The result."
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_output fails outside of knit_register" {
    run knit_with_output "result:integer" "0" "The result."
    [ "$status" -eq 1 ]
}

@test "knit_with_output rejects invalid output name" {
    knit_register "out_cmd_4" knit_empty "A test command."
    run knit_with_output "invalid name:string" "x" "Bad name."
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_output rejects duplicate output name" {
    knit_register "out_cmd_5" knit_empty "A test command."
    knit_with_output "result:integer" "0" "First declaration."
    run knit_with_output "result:integer" "1" "Duplicate."
    [ "$status" -eq 1 ]
    knit_done
}

# ---------- knit_with_output --result ----------

@test "knit_with_output --result marks the output as a result" {
    knit_register "res_cmd_1" knit_empty "A test command."
    knit_with_output "score:real" "0.0" "The score." --result
    knit_done
    _knit_set_find "_KNIT_CMD_res_cmd_1_results" "score"
}

@test "knit_with_output without --result leaves the results set unpopulated" {
    knit_register "res_cmd_2" knit_empty "A test command."
    knit_with_output "score:real" "0.0" "The score."
    knit_done
    run _knit_set_find "_KNIT_CMD_res_cmd_2_results" "score"
    [ "$status" -ne 0 ]
}

@test "knit_with_output --result is valid on any type" {
    knit_register "res_cmd_3" knit_empty "A test command."
    knit_with_output "note:string"  ""    "A note."  --result
    knit_with_output "count:integer" "0"  "A count." --result
    knit_done
    _knit_set_find "_KNIT_CMD_res_cmd_3_results" "note"
    _knit_set_find "_KNIT_CMD_res_cmd_3_results" "count"
}

@test "knit_with_output --result marks only the flagged output" {
    knit_register "res_cmd_4" knit_empty "A test command."
    knit_with_output "kept:real"    "0.0" "Kept."    --result
    knit_with_output "dropped:real" "0.0" "Dropped."
    knit_done
    _knit_set_find "_KNIT_CMD_res_cmd_4_results" "kept"
    run _knit_set_find "_KNIT_CMD_res_cmd_4_results" "dropped"
    [ "$status" -ne 0 ]
}

@test "knit_with_output --result normalizes hyphen to underscore" {
    knit_register "res_cmd_5" knit_empty "A test command."
    knit_with_output "my-score:real" "0.0" "The score." --result
    knit_done
    _knit_set_find "_KNIT_CMD_res_cmd_5_results" "my_score"
}

@test "knit_with_output rejects an unexpected flag" {
    knit_register "res_cmd_6" knit_empty "A test command."
    run knit_with_output "score:real" "0.0" "The score." --bogus
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
    knit_register "ko_fail_cmd" ko_fail_fn "Test."
    knit_with_output "result:integer" "0" "The result."
    knit_done
    run _knit_invoke_command "ko_fail_cmd"
    [ "$status" -eq 1 ]
}

@test "knit_output fails on type mismatch" {
    ko_type_fn() { knit_output "result" "not_an_integer"; }
    knit_register "ko_type_cmd" ko_type_fn "Test."
    knit_with_output "result:integer" "0" "The result."
    knit_done
    run _knit_invoke_command "ko_type_cmd"
    [ "$status" -eq 1 ]
}

@test "knit_output sets value in output array" {
    ko_set_fn() { knit_output "result" "42"; }
    knit_register "ko_set_cmd" ko_set_fn "Test."
    knit_with_output "result:integer" "0" "The result."
    knit_done
    _knit_invoke_command "ko_set_cmd"
    [ "${_KNIT_CMD_ko_set_cmd_output_value[result]}" = "42" ]
}

@test "knit_output normalizes hyphen to underscore in name" {
    ko_hyp_fn() { knit_output "my-result" "7"; }
    knit_register "ko_hyp_cmd" ko_hyp_fn "Test."
    knit_with_output "my-result:integer" "0" "The result."
    knit_done
    _knit_invoke_command "ko_hyp_cmd"
    [ "${_KNIT_CMD_ko_hyp_cmd_output_value[my_result]}" = "7" ]
}

@test "knit_output discards the value when _KNIT_RECORDING_SUPPRESSED is set" {
    ko_sup_fn() { knit_output "result" "42"; }
    knit_register "ko_sup_cmd" ko_sup_fn "Test."
    knit_with_output "result:integer" "0" "The result."
    knit_done
    # Non-root ranks of a run set this flag; knit_output must discard the value so
    # the app body can call it unconditionally.
    _KNIT_RECORDING_SUPPRESSED="1"
    _knit_invoke_command "ko_sup_cmd"
    [ -z "${_KNIT_CMD_ko_sup_cmd_output_value[result]:-}" ]
}

@test "knit_output warns when _KNIT_RECORDING_SUPPRESSED is set" {
    ko_supw_fn() { knit_output "result" "42"; }
    knit_register "ko_supw_cmd" ko_supw_fn "Test."
    knit_with_output "result:integer" "0" "The result."
    knit_done
    _KNIT_RECORDING_SUPPRESSED="1"
    run _knit_invoke_command "ko_supw_cmd"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Recording is suppressed"* ]]
    [[ "$output" == *"result"* ]]
}

@test "knit_output records normally when _KNIT_RECORDING_SUPPRESSED is empty (regression)" {
    ko_uns_fn() { knit_output "result" "42"; }
    knit_register "ko_uns_cmd" ko_uns_fn "Test."
    knit_with_output "result:integer" "0" "The result."
    knit_done
    _KNIT_RECORDING_SUPPRESSED=""
    _knit_invoke_command "ko_uns_cmd"
    [ "${_KNIT_CMD_ko_uns_cmd_output_value[result]}" = "42" ]
}

@test "knit_output nested invocation preserves outer context" {
    ko_inner_fn() { knit_output "inner_out" "inner_val"; }
    knit_register "ko_inner_cmd" ko_inner_fn "Test."
    knit_with_output "inner_out:string" "" "Inner output."
    knit_done
    ko_outer_fn() {
        _knit_invoke_command "ko_inner_cmd"
        knit_output "outer_out" "outer_val"
    }
    knit_register "ko_outer_cmd" ko_outer_fn "Test."
    knit_with_output "outer_out:string" "" "Outer output."
    knit_done
    _knit_invoke_command "ko_outer_cmd"
    [ "${_KNIT_CMD_ko_inner_cmd_output_value[inner_out]}" = "inner_val" ]
    [ "${_KNIT_CMD_ko_outer_cmd_output_value[outer_out]}" = "outer_val" ]
}

# ---------- _knit_output_description / _knit_output_default / _knit_output_type ----------

@test "_knit_output_description returns stored description" {
    knit_register "od_cmd" knit_empty "Test."
    knit_with_output "score:real" "0.0" "The score."
    knit_done
    local result
    _knit_output_description result "od_cmd" "score"
    [ "$result" = "The score." ]
}

@test "_knit_output_default returns stored default value" {
    knit_register "odef_cmd" knit_empty "Test."
    knit_with_output "count:integer" "42" "A count."
    knit_done
    local result
    _knit_output_default result "odef_cmd" "count"
    [ "$result" = "42" ]
}

@test "_knit_output_type returns stored type" {
    knit_register "ot_cmd" knit_empty "Test."
    knit_with_output "count:integer" "0" "A count."
    knit_done
    local result
    _knit_output_type result "ot_cmd" "count"
    [ "$result" = "integer" ]
}


# ---------- checksum declaration wiring (file/directory) ----------

@test "file required parameter synthesizes a checksum output column and marker" {
    knit_register "cs_file_cmd" knit_empty "Test."
    knit_with_required "data:file" "An input dataset."
    knit_done
    # Marker recorded as "<direction>:<kind>:<checksum>".
    _knit_set_find "_KNIT_CMD_cs_file_cmd_fileparams" "data"
    [ "${_KNIT_CMD_cs_file_cmd_fileparam_data}" = "input:file:yes" ]
    # Companion output column is registered, of type string.
    _knit_set_find "_KNIT_CMD_cs_file_cmd_outputs" "data_checksum"
    [ "${_KNIT_CMD_cs_file_cmd_3_data_checksum_type}" = "string" ]
}

@test "file optional parameter synthesizes a checksum column" {
    knit_register "cs_opt_cmd" knit_empty "Test."
    knit_with_optional "data:file" "" "An input dataset."
    knit_done
    _knit_set_find "_KNIT_CMD_cs_opt_cmd_fileparams" "data"
    [ "${_KNIT_CMD_cs_opt_cmd_fileparam_data}" = "input:file:yes" ]
    _knit_set_find "_KNIT_CMD_cs_opt_cmd_outputs" "data_checksum"
}

@test "directory parameter synthesizes a checksum column with kind directory" {
    knit_register "cs_dir_cmd" knit_empty "Test."
    knit_with_required "tree:directory" "An input tree."
    knit_done
    [ "${_KNIT_CMD_cs_dir_cmd_fileparam_tree}" = "input:directory:yes" ]
    _knit_set_find "_KNIT_CMD_cs_dir_cmd_outputs" "tree_checksum"
}

@test "dir alias parameter is checksummed as directory" {
    knit_register "cs_diralias_cmd" knit_empty "Test."
    knit_with_required "tree:dir" "An input tree."
    knit_done
    [ "${_KNIT_CMD_cs_diralias_cmd_fileparam_tree}" = "input:directory:yes" ]
    _knit_set_find "_KNIT_CMD_cs_diralias_cmd_outputs" "tree_checksum"
}

@test "file output synthesizes a checksum column with direction output" {
    knit_register "cs_out_cmd" knit_empty "Test."
    knit_with_output "result:file" "" "A produced file."
    knit_done
    [ "${_KNIT_CMD_cs_out_cmd_fileparam_result}" = "output:file:yes" ]
    _knit_set_find "_KNIT_CMD_cs_out_cmd_outputs" "result_checksum"
}

@test "--no-checksum keeps the existence marker but drops the companion column" {
    knit_register "cs_no_cmd" knit_empty "Test."
    knit_with_required "data:file" "An input dataset." --no-checksum
    knit_done
    # The marker is still recorded (existence is enforced) but with checksum "no".
    _knit_set_find "_KNIT_CMD_cs_no_cmd_fileparams" "data"
    [ "${_KNIT_CMD_cs_no_cmd_fileparam_data}" = "input:file:no" ]
    # No companion checksum output column is registered.
    run _knit_set_find "_KNIT_CMD_cs_no_cmd_outputs" "data_checksum"
    [ "$status" -ne 0 ]
}

@test "--no-checksum on an output keeps the marker but drops the companion column" {
    knit_register "cs_noout_cmd" knit_empty "Test."
    knit_with_output "scratch:directory" "" "A large scratch tree." --no-checksum
    knit_done
    [ "${_KNIT_CMD_cs_noout_cmd_fileparam_scratch}" = "output:directory:no" ]
    run _knit_set_find "_KNIT_CMD_cs_noout_cmd_outputs" "scratch_checksum"
    [ "$status" -ne 0 ]
}

@test "--no-checksum on a non-file parameter is fatal" {
    knit_register "cs_bad_cmd" knit_empty "Test."
    run knit_with_required "count:integer" "A count." --no-checksum
    [ "$status" -ne 0 ]
    [[ "$output" == *"--no-checksum flag is only valid"* ]]
}

@test "path and filename parameters are not checksummed" {
    knit_register "cs_path_cmd" knit_empty "Test."
    knit_with_required "p:path" "A path."
    knit_with_required "f:filename" "A filename."
    knit_done
    run _knit_set_find "_KNIT_CMD_cs_path_cmd_outputs" "p_checksum"
    [ "$status" -ne 0 ]
    run _knit_set_find "_KNIT_CMD_cs_path_cmd_outputs" "f_checksum"
    [ "$status" -ne 0 ]
}

@test "companion collides with an output declared afterwards" {
    knit_register "cs_col1_cmd" knit_empty "Test."
    knit_with_required "data:file" "An input dataset."
    run knit_with_output "data-checksum:string" "" "Manual clash."
    [ "$status" -ne 0 ]
}

@test "companion collides with an output declared beforehand" {
    knit_register "cs_col2_cmd" knit_empty "Test."
    knit_with_output "data-checksum:string" "" "Manual clash."
    run knit_with_required "data:file" "An input dataset."
    [ "$status" -ne 0 ]
}

@test "companion collides with a parameter declared afterwards" {
    knit_register "cs_col3_cmd" knit_empty "Test."
    knit_with_required "data:file" "An input dataset."
    run knit_with_required "data_checksum:string" "A clashing parameter."
    [ "$status" -ne 0 ]
}

@test "companion collides with a parameter declared beforehand" {
    knit_register "cs_col4_cmd" knit_empty "Test."
    knit_with_required "data_checksum:string" "A parameter."
    run knit_with_required "data:file" "An input dataset."
    [ "$status" -ne 0 ]
}
