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

# ---------- knit_empty ----------

@test "knit_empty returns 0" {
    knit_empty
}

# ---------- __knit_command_mangle ----------

@test "__knit_command_mangle converts colons to __1__" {
    local result
    result=$(__knit_command_mangle "foo:bar:baz")
    [ "$result" = "foo__1__bar__1__baz" ]
}

@test "__knit_command_mangle converts spaces to __1__" {
    local result
    result=$(__knit_command_mangle "foo bar baz")
    [ "$result" = "foo__1__bar__1__baz" ]
}

@test "__knit_command_mangle leaves single word unchanged" {
    local result
    result=$(__knit_command_mangle "foo")
    [ "$result" = "foo" ]
}

# ---------- __knit_command_demangle ----------

@test "__knit_command_demangle converts __1__ back to colons" {
    local result
    result=$(__knit_command_demangle "foo__1__bar__1__baz")
    [ "$result" = "foo:bar:baz" ]
}

@test "__knit_command_demangle leaves single word unchanged" {
    local result
    result=$(__knit_command_demangle "foo")
    [ "$result" = "foo" ]
}

# ---------- __knit_command_with_space ----------

@test "__knit_command_with_space converts __1__ to spaces" {
    local result
    result=$(__knit_command_with_space "foo__1__bar__1__baz")
    [ "$result" = "foo bar baz" ]
}

@test "__knit_command_with_space converts colons to spaces" {
    local result
    result=$(__knit_command_with_space "foo:bar:baz")
    [ "$result" = "foo bar baz" ]
}

# ---------- __knit_name_normalize ----------

@test "__knit_name_normalize converts hyphens to underscores" {
    local result
    result=$(__knit_name_normalize "my-param-name")
    [ "$result" = "my_param_name" ]
}

@test "__knit_name_normalize leaves underscores unchanged" {
    local result
    result=$(__knit_name_normalize "my_param_name")
    [ "$result" = "my_param_name" ]
}

# ---------- __knit_name_is_valid ----------

@test "__knit_name_is_valid accepts valid names" {
    __knit_name_is_valid "abc"
    __knit_name_is_valid "abc123"
    __knit_name_is_valid "abc-def"
    __knit_name_is_valid "abc_def"
    __knit_name_is_valid "A1_b-c"
    __knit_name_is_valid "_private"
}

@test "__knit_name_is_valid rejects empty string" {
    run __knit_name_is_valid ""
    [ "$status" -eq 1 ]
}

@test "__knit_name_is_valid rejects names with spaces" {
    run __knit_name_is_valid "abc def"
    [ "$status" -eq 1 ]
}

@test "__knit_name_is_valid rejects names with colons" {
    run __knit_name_is_valid "abc:def"
    [ "$status" -eq 1 ]
}

@test "__knit_name_is_valid rejects reserved constraint keywords" {
    run __knit_name_is_valid "true";  [ "$status" -eq 1 ]
    run __knit_name_is_valid "false"; [ "$status" -eq 1 ]
    run __knit_name_is_valid "null";  [ "$status" -eq 1 ]
    run __knit_name_is_valid "and";   [ "$status" -eq 1 ]
    run __knit_name_is_valid "or";    [ "$status" -eq 1 ]
    run __knit_name_is_valid "not";   [ "$status" -eq 1 ]
}

# ---------- __knit_command_get_parents ----------

@test "__knit_command_get_parents returns parent for colon-separated command" {
    local result
    result=$(__knit_command_get_parents "aaa:bbb:ccc")
    [ "$result" = "aaa:bbb" ]
}

@test "__knit_command_get_parents returns parent for mangled command" {
    local result
    result=$(__knit_command_get_parents "aaa__1__bbb__1__ccc")
    [ "$result" = "aaa__1__bbb" ]
}

@test "__knit_command_get_parents returns parent for space-separated command" {
    local result
    result=$(__knit_command_get_parents "aaa bbb ccc")
    [ "$result" = "aaa bbb" ]
}

@test "__knit_command_get_parents returns empty for top-level command" {
    local result
    result=$(__knit_command_get_parents "aaa")
    [ -z "$result" ]
}

# ---------- __knit_command_get_last ----------

@test "__knit_command_get_last returns last part for colon-separated command" {
    local result
    result=$(__knit_command_get_last "aaa:bbb:ccc")
    [ "$result" = "ccc" ]
}

@test "__knit_command_get_last returns last part for mangled command" {
    local result
    result=$(__knit_command_get_last "aaa__1__bbb__1__ccc")
    [ "$result" = "ccc" ]
}

@test "__knit_command_get_last returns entire string for single-level command" {
    local result
    result=$(__knit_command_get_last "aaa")
    [ "$result" = "aaa" ]
}

# ---------- __knit_param_description_var / __knit_param_default_var / __knit_param_type_var ----------

@test "__knit_param_description_var returns expected variable name" {
    local result
    result=$(__knit_param_description_var "mycmd" "myparam")
    [ "$result" = "_KNIT_CMD_mycmd_2_myparam_description" ]
}

@test "__knit_param_default_var returns expected variable name" {
    local result
    result=$(__knit_param_default_var "mycmd" "myparam")
    [ "$result" = "_KNIT_CMD_mycmd_2_myparam_default" ]
}

@test "__knit_param_type_var returns expected variable name" {
    local result
    result=$(__knit_param_type_var "mycmd" "myparam")
    [ "$result" = "_KNIT_CMD_mycmd_2_myparam_type" ]
}

# ---------- __knit_param_description / __knit_param_default / __knit_param_type ----------

@test "__knit_param_description returns stored description" {
    knit_register knit_empty "pd_cmd" "Test."
    knit_with_optional "value:string" "default_val" "My description."
    knit_done
    local result
    result=$(__knit_param_description "pd_cmd" "value")
    [ "$result" = "My description." ]
}

@test "__knit_param_default returns stored default value" {
    knit_register knit_empty "pdef_cmd" "Test."
    knit_with_optional "count:integer" "42" "A count."
    knit_done
    local result
    result=$(__knit_param_default "pdef_cmd" "count")
    [ "$result" = "42" ]
}

@test "__knit_param_type returns stored type" {
    knit_register knit_empty "pt_cmd" "Test."
    knit_with_required "count:integer" "A count."
    knit_done
    local result
    result=$(__knit_param_type "pt_cmd" "count")
    [ "$result" = "integer" ]
}

# ---------- knit_register / knit_done ----------

@test "knit_register adds command to registry" {
    knit_register knit_empty "reg_cmd" "A registered command."
    knit_done
    _knit_set_find _KNIT_COMMANDS "reg_cmd"
}

@test "knit_register fails with invalid character in command name" {
    run knit_register knit_empty "my cmd" "Bad command."
    [ "$status" -eq 1 ]
}

@test "knit_register fails if parent command not registered" {
    run knit_register knit_empty "parent:child" "Child command."
    [ "$status" -eq 1 ]
}

@test "knit_register fails if command already registered" {
    knit_register knit_empty "dup_cmd" "First registration."
    knit_done
    run knit_register knit_empty "dup_cmd" "Second registration."
    [ "$status" -eq 1 ]
}

@test "knit_register allows subcommand when parent is registered" {
    knit_register knit_empty "par_cmd" "Parent command."
    knit_done
    knit_register knit_empty "par_cmd:sub" "Subcommand."
    knit_done
    _knit_set_find _KNIT_COMMANDS "par_cmd__1__sub"
}

@test "knit_done fails if registered function is not defined" {
    knit_register undefined_fn "undef_cmd" "Test."
    run knit_done
    [ "$status" -eq 1 ]
}

# ---------- __knit_push_done_cb ----------

@test "__knit_push_done_cb fails outside of knit_register" {
    run __knit_push_done_cb echo "hello"
    [ "$status" -eq 1 ]
}

@test "__knit_push_done_cb callback is invoked at knit_done" {
    _KNIT_PDC_CALLED=false
    _pdc_mark_called() { _KNIT_PDC_CALLED=true; }
    pdc_fn_a() { :; }
    knit_register pdc_fn_a "pdc_a" "Test."
    __knit_push_done_cb _pdc_mark_called
    knit_done
    [ "${_KNIT_PDC_CALLED}" = "true" ]
}

@test "__knit_push_done_cb multiple callbacks run in reverse order" {
    declare -ga _KNIT_PDC_ORDER=()
    _pdc_order_append() { _KNIT_PDC_ORDER+=("$1"); }
    pdc_fn_b() { :; }
    knit_register pdc_fn_b "pdc_b" "Test."
    __knit_push_done_cb _pdc_order_append "first"
    __knit_push_done_cb _pdc_order_append "second"
    __knit_push_done_cb _pdc_order_append "third"
    knit_done
    [ "${_KNIT_PDC_ORDER[0]}" = "third" ]
    [ "${_KNIT_PDC_ORDER[1]}" = "second" ]
    [ "${_KNIT_PDC_ORDER[2]}" = "first" ]
}

@test "__knit_push_done_cb _KNIT_DONE_CBS is unset after knit_done" {
    pdc_fn_c() { :; }
    knit_register pdc_fn_c "pdc_c" "Test."
    __knit_push_done_cb echo "cb"
    knit_done
    [[ ! -v _KNIT_DONE_CBS ]]
}

@test "__knit_push_done_cb callbacks do not carry over to next registration" {
    _KNIT_PDC_COUNT=0
    _pdc_increment() { _KNIT_PDC_COUNT=$(( _KNIT_PDC_COUNT + 1 )); }
    pdc_fn_d() { :; }
    knit_register pdc_fn_d "pdc_d" "Test."
    __knit_push_done_cb _pdc_increment
    pdc_fn_e() { :; }
    knit_register pdc_fn_e "pdc_e" "Test."
    # implicit knit_done fired for pdc_d: count becomes 1
    knit_done
    # explicit knit_done for pdc_e: no callbacks pushed, count stays 1
    [ "${_KNIT_PDC_COUNT}" -eq 1 ]
}

# ---------- knit_hidden ----------

@test "knit_hidden marks a command as hidden" {
    knit_register knit_empty "hid_cmd" "A hidden command."
    knit_hidden
    knit_done
    [ "${_KNIT_CMD_hid_cmd_is_hidden}" = "true" ]
}

@test "knit_hidden fails outside of knit_register" {
    run knit_hidden
    [ "$status" -eq 1 ]
}

# ---------- knit_with_subcommand_title ----------

@test "knit_with_subcommand_title sets the subcommand title" {
    knit_register knit_empty "sct_cmd" "Test."
    knit_with_subcommand_title "My Operations"
    knit_done
    [ "${_KNIT_CMD_sct_cmd_sucommand_title}" = "My Operations" ]
}

@test "knit_with_subcommand_title fails outside of knit_register" {
    run knit_with_subcommand_title "title"
    [ "$status" -eq 1 ]
}

# ---------- knit_with_flag ----------

@test "knit_with_flag registers a flag" {
    knit_register knit_empty "flg_cmd" "Test."
    knit_with_flag "verbose" "Enable verbose output."
    knit_done
    _knit_set_find "_KNIT_CMD_flg_cmd_flags" "verbose"
}

@test "knit_with_flag normalizes hyphens to underscores" {
    knit_register knit_empty "flg_cmd2" "Test."
    knit_with_flag "dry-run" "Dry run mode."
    knit_done
    _knit_set_find "_KNIT_CMD_flg_cmd2_flags" "dry_run"
}

@test "knit_with_flag fails outside of knit_register" {
    run knit_with_flag "verbose" "Enable verbose output."
    [ "$status" -eq 1 ]
}

@test "knit_with_flag rejects invalid flag name" {
    knit_register knit_empty "flg_cmd3" "Test."
    run knit_with_flag "invalid name" "Has a space."
    [ "$status" -eq 1 ]
}

# ---------- knit_with_extra ----------

@test "knit_with_extra stores the extra description" {
    knit_register knit_empty "ext_cmd" "Test."
    knit_with_extra "Extra arguments passed after --."
    knit_done
    [ "${_KNIT_CMD_ext_cmd_extra}" = "Extra arguments passed after --." ]
}

@test "knit_with_extra fails outside of knit_register" {
    run knit_with_extra "Extra args."
    [ "$status" -eq 1 ]
}

# ---------- __knit_param_check_declaration (edge cases) ----------

@test "knit_with_required fails outside of knit_register" {
    run knit_with_required "name:string" "A name."
    [ "$status" -eq 1 ]
}

@test "knit_with_required rejects invalid parameter name" {
    knit_register knit_empty "inv_cmd" "Test."
    run knit_with_required "invalid name:string" "A name."
    [ "$status" -eq 1 ]
}

@test "knit_with_required rejects duplicate parameter name" {
    knit_register knit_empty "dup_param_cmd" "Test."
    knit_with_required "name:string" "First declaration."
    run knit_with_required "name:string" "Duplicate."
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_optional fails outside of knit_register" {
    run knit_with_optional "name:string" "default" "A name."
    [ "$status" -eq 1 ]
}

# ---------- _knit_run_before / _knit_run_after ----------

@test "_knit_run_before registers a before callback" {
    knit_register knit_empty "rb_cmd" "Test."
    _knit_run_before echo "before_output"
    knit_done
    [ "${#_KNIT_CMD_rb_cmd_before_cb[@]}" -eq 1 ]
}

@test "_knit_run_before fails outside of knit_register" {
    run _knit_run_before echo "before"
    [ "$status" -eq 1 ]
}

@test "_knit_run_after registers an after callback" {
    knit_register knit_empty "ra_cmd" "Test."
    _knit_run_after echo "after_output"
    knit_done
    [ "${#_KNIT_CMD_ra_cmd_after_cb[@]}" -eq 1 ]
}

@test "_knit_run_after fails outside of knit_register" {
    run _knit_run_after echo "after"
    [ "$status" -eq 1 ]
}

# ---------- __knit_execute_before_commands / __knit_execute_after_commands ----------

@test "__knit_execute_before_commands executes registered callbacks" {
    knit_register knit_empty "eb_cmd" "Test."
    _knit_run_before echo "before_output"
    knit_done
    local result
    result=$(__knit_execute_before_commands "eb_cmd")
    [ "$result" = "before_output" ]
}

@test "__knit_execute_before_commands does nothing when no callbacks registered" {
    knit_register knit_empty "eb_cmd2" "Test."
    knit_done
    local result
    result=$(__knit_execute_before_commands "eb_cmd2")
    [ -z "$result" ]
}

@test "__knit_execute_after_commands executes registered callbacks" {
    knit_register knit_empty "ea_cmd" "Test."
    _knit_run_after echo "after_output"
    knit_done
    local result
    result=$(__knit_execute_after_commands "ea_cmd")
    [ "$result" = "after_output" ]
}

@test "__knit_execute_after_commands does nothing when no callbacks registered" {
    knit_register knit_empty "ea_cmd2" "Test."
    knit_done
    local result
    result=$(__knit_execute_after_commands "ea_cmd2")
    [ -z "$result" ]
}

# ---------- __knit_find_flag ----------

@test "__knit_find_flag returns 0 when flag is present" {
    __knit_find_flag "--verbose" "aaa" "--verbose" "bbb"
}

@test "__knit_find_flag returns 1 when flag is absent" {
    run __knit_find_flag "--verbose" "aaa" "bbb"
    [ "$status" -eq 1 ]
}

@test "__knit_find_flag stops searching after double dash" {
    run __knit_find_flag "--verbose" "aaa" "--" "--verbose"
    [ "$status" -eq 1 ]
}

@test "__knit_find_flag matches hyphen and underscore variants" {
    __knit_find_flag "--dry-run" "--dry_run"
    __knit_find_flag "--dry_run" "--dry-run"
}

# ---------- _knit_check_command_arguments ----------

@test "_knit_check_command_arguments passes when all required args are present" {
    knit_register knit_empty "ca_cmd" "Test."
    knit_with_required "name:string" "A name."
    knit_done
    _knit_check_command_arguments "ca_cmd" "--name" "Alice"
}

@test "_knit_check_command_arguments fails when required arg is missing" {
    knit_register knit_empty "ca_cmd2" "Test."
    knit_with_required "name:string" "A name."
    knit_done
    run _knit_check_command_arguments "ca_cmd2"
    [ "$status" -eq 1 ]
}

@test "_knit_check_command_arguments fails for unexpected argument" {
    knit_register knit_empty "ca_cmd3" "Test."
    knit_done
    run _knit_check_command_arguments "ca_cmd3" "--unknown" "value"
    [ "$status" -eq 1 ]
}

@test "_knit_check_command_arguments fails for extra args when not declared" {
    knit_register knit_empty "ca_cmd4" "Test."
    knit_done
    run _knit_check_command_arguments "ca_cmd4" "--" "extra_arg"
    [ "$status" -eq 1 ]
}

@test "_knit_check_command_arguments passes with extra args when declared" {
    knit_register knit_empty "ca_cmd5" "Test."
    knit_with_extra "Extra arguments."
    knit_done
    _knit_check_command_arguments "ca_cmd5" "--" "extra_arg"
}

@test "_knit_check_command_arguments accepts flags without values" {
    knit_register knit_empty "ca_cmd6" "Test."
    knit_with_flag "verbose" "Verbose mode."
    knit_done
    _knit_check_command_arguments "ca_cmd6" "--verbose"
}

# ---------- __knit_expand_command_arguments ----------

@test "__knit_expand_command_arguments fills in optional defaults" {
    knit_register knit_empty "expa_cmd" "Test."
    knit_with_optional "count:integer" "10" "A count."
    knit_done
    local -a args
    readarray -d '' -t args < <(__knit_expand_command_arguments "expa_cmd")
    local val
    val=$(knit_get_parameter "count" "${args[@]}")
    [ "$val" = "10" ]
}

@test "__knit_expand_command_arguments does not override provided optional" {
    knit_register knit_empty "expa_cmd2" "Test."
    knit_with_optional "count:integer" "10" "A count."
    knit_done
    local -a args
    readarray -d '' -t args < <(__knit_expand_command_arguments "expa_cmd2" "--count" "99")
    local val
    val=$(knit_get_parameter "count" "${args[@]}")
    [ "$val" = "99" ]
}

@test "__knit_expand_command_arguments expands --key=value syntax" {
    knit_register knit_empty "expa_cmd3" "Test."
    knit_with_required "name:string" "A name."
    knit_done
    local -a args
    readarray -d '' -t args < <(__knit_expand_command_arguments "expa_cmd3" "--name=Alice")
    local val
    val=$(knit_get_parameter "name" "${args[@]}")
    [ "$val" = "Alice" ]
}

@test "__knit_expand_command_arguments converts present flag to true" {
    knit_register knit_empty "expa_cmd4" "Test."
    knit_with_flag "verbose" "Enable verbose."
    knit_done
    local -a args
    readarray -d '' -t args < <(__knit_expand_command_arguments "expa_cmd4" "--verbose")
    local val
    val=$(knit_get_parameter "verbose" "${args[@]}")
    [ "$val" = "true" ]
}

@test "__knit_expand_command_arguments converts absent flag to false" {
    knit_register knit_empty "expa_cmd5" "Test."
    knit_with_flag "verbose" "Enable verbose."
    knit_done
    local -a args
    readarray -d '' -t args < <(__knit_expand_command_arguments "expa_cmd5")
    local val
    val=$(knit_get_parameter "verbose" "${args[@]}")
    [ "$val" = "false" ]
}

# ---------- _knit_invoke_command ----------

@test "_knit_invoke_command invokes a registered command with arguments" {
    knit_register fn_ic "ic_cmd" "Test."
    knit_with_required "name:string" "A name."
    fn_ic() {
        local name
        name=$(knit_get_parameter "name" "$@")
        echo "Hello, ${name}!"
    }
    knit_done
    local result
    result=$(_knit_invoke_command "ic_cmd" "--name" "World")
    [ "$result" = "Hello, World!" ]
}

@test "_knit_invoke_command fails for unknown command" {
    run _knit_invoke_command "nonexistent_cmd_xyz"
    [ "$status" -eq 1 ]
}

@test "_knit_invoke_command fills optional defaults before invoking" {
    knit_register fn_ic2 "ic_cmd2" "Test."
    knit_with_optional "count:integer" "7" "A count."
    fn_ic2() {
        local count
        count=$(knit_get_parameter "count" "$@")
        echo "${count}"
    }
    knit_done
    local result
    result=$(_knit_invoke_command "ic_cmd2")
    [ "$result" = "7" ]
}

@test "_knit_invoke_command invokes subcommand" {
    knit_register knit_empty "par2_cmd" "Parent."
    knit_done
    knit_register fn_child "par2_cmd:child" "Child."
    knit_with_required "msg:string" "A message."
    fn_child() {
        local msg
        msg=$(knit_get_parameter "msg" "$@")
        echo "${msg}"
    }
    knit_done
    local result
    result=$(_knit_invoke_command "par2_cmd" "child" "--msg" "hello")
    [ "$result" = "hello" ]
}

@test "_knit_invoke_command shows help output with --help" {
    knit_register knit_empty "ic_cmd3" "A test command for help."
    knit_with_required "name:string" "A name."
    knit_done
    local result
    result=$(_knit_invoke_command "ic_cmd3" "--help")
    [[ "$result" == *"ic_cmd3"* ]]
    [[ "$result" == *"--name"* ]]
    [[ "$result" == *"--help"* ]]
}

@test "_knit_invoke_command runs before and after callbacks in order" {
    knit_register fn_ic4 "ic_cmd4" "Test."
    _knit_run_before echo "before"
    _knit_run_after echo "after"
    fn_ic4() { echo "body"; }
    knit_done
    local result
    result=$(_knit_invoke_command "ic_cmd4")
    local before_pos body_pos after_pos
    before_pos=$(echo "$result" | grep -n "before" | cut -d: -f1)
    body_pos=$(echo "$result" | grep -n "body" | cut -d: -f1)
    after_pos=$(echo "$result" | grep -n "after" | cut -d: -f1)
    [ "$before_pos" -lt "$body_pos" ]
    [ "$body_pos" -lt "$after_pos" ]
}

# ---------- knit_extra_index ----------

@test "knit_extra_index returns array length when no -- is present" {
    local args=("--foo" "bar" "--baz" "qux")
    local result
    result=$(knit_extra_index "${args[@]}")
    [ "$result" = "4" ]
}

@test "knit_extra_index returns index after -- when present" {
    local args=("--foo" "bar" "--" "extra1" "extra2")
    local result
    result=$(knit_extra_index "${args[@]}")
    [ "$result" = "3" ]
}

@test "knit_extra_index returns 1 when -- is first element" {
    local args=("--" "extra1")
    local result
    result=$(knit_extra_index "${args[@]}")
    [ "$result" = "1" ]
}

@test "knit_extra_index returns 0 for empty array" {
    local result
    result=$(knit_extra_index)
    [ "$result" = "0" ]
}

# ---------- knit_set_program_description ----------

@test "knit_set_program_description stores the description" {
    knit_set_program_description "My awesome program."
    [ "${_KNIT_CMD___main___description}" = "My awesome program." ]
}

@test "knit_set_program_description handles special characters" {
    knit_set_program_description "A program with 'quotes' and spaces."
    [ "${_KNIT_CMD___main___description}" = "A program with 'quotes' and spaces." ]
}

# ---------- knit_with_table ----------

@test "knit_with_table defaults to colon-separated command name" {
    knit_register knit_empty "foo" "A parent command."
    knit_done
    knit_register knit_empty "foo:bar" "A subcommand."
    knit_with_table
    knit_done
    local result
    result=$(sqlite3 "${__KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='foo:bar';")
    [ "$result" -eq 1 ]
}

@test "knit_with_table accepts an explicit table name" {
    knit_register knit_empty "mycmd" "A command."
    knit_with_table "my_runs"
    knit_done
    local result
    result=$(sqlite3 "${__KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='my_runs';")
    [ "$result" -eq 1 ]
}

@test "knit_with_table for a simple command defaults to command name" {
    knit_register knit_empty "run" "Run something."
    knit_with_table
    knit_done
    local result
    result=$(sqlite3 "${__KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='run';")
    [ "$result" -eq 1 ]
}

@test "two commands with distinct table names both succeed" {
    knit_register knit_empty "cmd1" "First command."
    knit_with_table "table1"
    knit_done

    knit_register knit_empty "cmd2" "Second command."
    knit_with_table "table2"
    knit_done

    local r1 r2
    r1=$(sqlite3 "${__KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='table1';")
    r2=$(sqlite3 "${__KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='table2';")
    [ "$r1" -eq 1 ]
    [ "$r2" -eq 1 ]
}

@test "two commands sharing a table name causes a fatal error" {
    knit_register knit_empty "cmd1" "First command."
    knit_with_table "shared"
    knit_done

    knit_register knit_empty "cmd2" "Second command."
    run knit_with_table "shared"
    [ "$status" -ne 0 ]
}

@test "knit_with_table outside registration context causes a fatal error" {
    run knit_with_table "mytable"
    [ "$status" -ne 0 ]
}

@test "table created by knit_with_table has id as first column" {
    knit_register knit_empty "mycmd" "A command."
    knit_with_required "count:integer" "A count."
    knit_with_table
    knit_done
    local first_col
    first_col=$(sqlite3 "${__KNIT_DATABASE}" \
        "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | head -1)
    [ "$first_col" = "id" ]
}

@test "table contains columns for all params flags and outputs" {
    knit_register knit_empty "mycmd" "A command."
    knit_with_required "iters:integer" "Iterations."
    knit_with_optional "label:string" "none" "A label."
    knit_with_flag "verbose" "Verbose mode."
    knit_with_output "score:real" "0.0" "The score."
    knit_with_table
    knit_done
    local names
    names=$(sqlite3 "${__KNIT_DATABASE}" \
        "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,iters,label,verbose,score," ]
}

@test "optional parameter default is used as migration default" {
    # Create the table first with only the id column (simulating old schema)
    knit_register knit_empty "mycmd" "A command."
    knit_with_table
    knit_done
    sqlite3 "${__KNIT_DATABASE}" \
        "INSERT INTO mycmd (id) VALUES ('550e8400-e29b-41d4-a716-446655440000');"

    # Now add an optional parameter and re-run setup directly
    _knit_set_add "_KNIT_CMD_mycmd_optional" "label"
    eval "_KNIT_CMD_mycmd_2_label_type=string"
    eval "_KNIT_CMD_mycmd_2_label_default=mydefault"
    _knit_db_setup_table "mycmd" "mycmd"

    local val
    val=$(sqlite3 "${__KNIT_DATABASE}" "SELECT label FROM mycmd;")
    [ "$val" = "mydefault" ]
}

# ---------- knit_define_parameter_set / knit_with_parameter_set ----------

@test "knit_define_parameter_set defines a parameter set" {
    knit_define_parameter_set "my_params"
    knit_done
    [[ -v "_KNIT_PARAMETER_SETS[my_params]" ]]
}

@test "knit_define_parameter_set with required/optional/flag stores params in pset namespace" {
    knit_define_parameter_set "job_params"
    knit_with_required "nodes:integer" "Node count."
    knit_with_optional "label:string" "none" "A label."
    knit_with_flag "verbose" "Verbose mode."
    knit_done
    _knit_set_find "_KNIT_PSET_job_params_required" "nodes"
    _knit_set_find "_KNIT_PSET_job_params_optional" "label"
    _knit_set_find "_KNIT_PSET_job_params_flags" "verbose"
}

@test "knit_with_parameter_set imports params into a command" {
    knit_define_parameter_set "shared"
    knit_with_required "nodes:integer" "Node count."
    knit_with_optional "label:string" "none" "A label."
    knit_with_flag "verbose" "Verbose mode."
    knit_done

    knit_register knit_empty "pset_cmd1" "A command."
    knit_with_parameter_set "shared"
    knit_done

    _knit_set_find "_KNIT_CMD_pset_cmd1_required" "nodes"
    _knit_set_find "_KNIT_CMD_pset_cmd1_optional" "label"
    _knit_set_find "_KNIT_CMD_pset_cmd1_flags" "verbose"
}

@test "knit_with_parameter_set copies parameter metadata" {
    knit_define_parameter_set "meta_set"
    knit_with_required "size:integer" "Size of the job."
    knit_with_optional "tag:string" "default_tag" "A tag."
    knit_done

    knit_register knit_empty "meta_cmd" "A command."
    knit_with_parameter_set "meta_set"
    knit_done

    [ "${_KNIT_CMD_meta_cmd_2_size_type}" = "integer" ]
    [ "${_KNIT_CMD_meta_cmd_2_size_description}" = "Size of the job." ]
    [ "${_KNIT_CMD_meta_cmd_2_tag_type}" = "string" ]
    [ "${_KNIT_CMD_meta_cmd_2_tag_default}" = "default_tag" ]
    [ "${_KNIT_CMD_meta_cmd_2_tag_description}" = "A tag." ]
}

@test "knit_with_parameter_set lets the command be invoked with pset params" {
    knit_define_parameter_set "run_params"
    knit_with_required "nodes:integer" "Node count."
    knit_with_optional "label:string" "default" "A label."
    knit_done

    local captured_nodes captured_label
    run_pset_cmd() {
        captured_nodes=$(knit_get_parameter "nodes" "$@")
        captured_label=$(knit_get_parameter "label" "$@")
    }
    knit_register run_pset_cmd "run_pset_cmd" "A command."
    knit_with_parameter_set "run_params"
    knit_done

    _knit_invoke_command "run_pset_cmd" "--nodes" "4"
    [ "${captured_nodes}" = "4" ]
    [ "${captured_label}" = "default" ]
}

@test "two commands can share the same parameter set independently" {
    knit_define_parameter_set "shared2"
    knit_with_required "nodes:integer" "Node count."
    knit_done

    local captured_a captured_b
    cmd_a() { captured_a=$(knit_get_parameter "nodes" "$@"); }
    cmd_b() { captured_b=$(knit_get_parameter "nodes" "$@"); }
    knit_register cmd_a "cmd_a" "Command A."
    knit_with_parameter_set "shared2"
    knit_done
    knit_register cmd_b "cmd_b" "Command B."
    knit_with_parameter_set "shared2"
    knit_done

    _knit_invoke_command "cmd_a" "--nodes" "2"
    _knit_invoke_command "cmd_b" "--nodes" "8"
    [ "${captured_a}" = "2" ]
    [ "${captured_b}" = "8" ]
}

@test "multiple parameter sets can be applied to one command" {
    knit_define_parameter_set "set_a"
    knit_with_required "nodes:integer" "Node count."
    knit_done
    knit_define_parameter_set "set_b"
    knit_with_required "walltime:integer" "Walltime in seconds."
    knit_done

    knit_register knit_empty "multi_pset_cmd" "A command."
    knit_with_parameter_set "set_a"
    knit_with_parameter_set "set_b"
    knit_done

    _knit_set_find "_KNIT_CMD_multi_pset_cmd_required" "nodes"
    _knit_set_find "_KNIT_CMD_multi_pset_cmd_required" "walltime"
}

@test "command-level params and pset params coexist" {
    knit_define_parameter_set "base_set"
    knit_with_required "nodes:integer" "Node count."
    knit_done

    knit_register knit_empty "mixed_cmd" "A command."
    knit_with_required "app:string" "Application name."
    knit_with_parameter_set "base_set"
    knit_done

    _knit_set_find "_KNIT_CMD_mixed_cmd_required" "app"
    _knit_set_find "_KNIT_CMD_mixed_cmd_required" "nodes"
}

@test "knit_with_parameter_set fails for undefined set" {
    knit_register knit_empty "nosuchset_cmd" "A command."
    run knit_with_parameter_set "nonexistent"
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_parameter_set fails when pset param conflicts with command param" {
    knit_define_parameter_set "conflict_set"
    knit_with_required "nodes:integer" "Node count."
    knit_done

    knit_register knit_empty "conflict_cmd" "A command."
    knit_with_required "nodes:integer" "Already declared."
    run knit_with_parameter_set "conflict_set"
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_parameter_set fails when two psets have the same param" {
    knit_define_parameter_set "overlap_a"
    knit_with_required "nodes:integer" "Node count."
    knit_done
    knit_define_parameter_set "overlap_b"
    knit_with_required "nodes:integer" "Same name."
    knit_done

    knit_register knit_empty "overlap_cmd" "A command."
    knit_with_parameter_set "overlap_a"
    run knit_with_parameter_set "overlap_b"
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_define_parameter_set fails for invalid name" {
    run knit_define_parameter_set "invalid name"
    [ "$status" -eq 1 ]
}

@test "knit_define_parameter_set fails for duplicate set name" {
    knit_define_parameter_set "dup_set"
    knit_done
    run knit_define_parameter_set "dup_set"
    [ "$status" -eq 1 ]
}

@test "knit_define_parameter_set fails inside another parameter set definition" {
    knit_define_parameter_set "outer_set"
    run knit_define_parameter_set "inner_set"
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_parameter_set fails outside of knit_register" {
    knit_define_parameter_set "standalone_set"
    knit_done
    run knit_with_parameter_set "standalone_set"
    [ "$status" -eq 1 ]
}

@test "knit_with_required fails with duplicate within a parameter set" {
    knit_define_parameter_set "dup_param_set"
    knit_with_required "nodes:integer" "First declaration."
    run knit_with_required "nodes:integer" "Duplicate."
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_define_parameter_set auto-calls knit_done if knit_register is open" {
    knit_register knit_empty "auto_done_cmd" "A command."
    knit_define_parameter_set "auto_done_set"
    knit_done
    # Both registrations should have completed without error.
    _knit_set_find _KNIT_COMMANDS "auto_done_cmd"
    [[ -v "_KNIT_PARAMETER_SETS[auto_done_set]" ]]
}

@test "pset params appear in --help output for the command" {
    knit_define_parameter_set "help_set"
    knit_with_required "nodes:integer" "Number of nodes."
    knit_done

    knit_register knit_empty "help_pset_cmd" "A command with pset params."
    knit_with_parameter_set "help_set"
    knit_done

    run _knit_invoke_command "help_pset_cmd" "--help"
    [[ "$output" == *"nodes"* ]]
}

# ---------- --when constraints ----------

@test "--when accepted on knit_with_required" {
    knit_register knit_empty "when_req_cmd" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when "x > 42"
    knit_done
}

@test "--when accepted on knit_with_optional" {
    knit_register knit_empty "when_opt_cmd" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_optional "y:integer" "0" "Y value." --when "x > 42"
    knit_done
}

@test "--when accepted on knit_with_flag" {
    knit_register knit_empty "when_flg_cmd" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_flag "verbose" "Verbose mode." --when "x > 42"
    knit_done
}

@test "--when stores preprocessed expression in metadata variable" {
    knit_register knit_empty "when_meta_cmd" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when "x > 42"
    knit_done
    [ "${_KNIT_CMD_when_meta_cmd_2_y_when}" = ".x > 42" ]
}

@test "constraint passes: required param provided when condition is true" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    __KNIT_JQ_EXE="jq"

    local captured_x captured_y
    constrained_cmd() {
        captured_x=$(knit_get_parameter "x" "$@")
        captured_y=$(knit_get_parameter "y" "$@")
    }
    knit_register constrained_cmd "constrained_cmd1" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when "x > 42"
    knit_done

    _knit_invoke_command "constrained_cmd1" "--x" "50" "--y" "10"
    [ "${captured_x}" = "50" ]
    [ "${captured_y}" = "10" ]
}

@test "constraint fails: required param missing when condition is true" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    __KNIT_JQ_EXE="jq"

    knit_register knit_empty "constrained_cmd2" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when "x > 42"
    knit_done

    run _knit_invoke_command "constrained_cmd2" "--x" "50"
    [ "$status" -eq 1 ]
}

@test "constraint passes: required param absent when condition is false" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    __KNIT_JQ_EXE="jq"

    knit_register knit_empty "constrained_cmd3" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when "x > 42"
    knit_done

    _knit_invoke_command "constrained_cmd3" "--x" "5"
}

@test "constraint fails: param provided when condition is false" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    __KNIT_JQ_EXE="jq"

    knit_register knit_empty "constrained_cmd4" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when "x > 42"
    knit_done

    run _knit_invoke_command "constrained_cmd4" "--x" "5" "--y" "10"
    [ "$status" -eq 1 ]
}

@test "optional param constraint: absent when condition false is OK" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    __KNIT_JQ_EXE="jq"

    knit_register knit_empty "opt_when_cmd1" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_optional "label:string" "none" "A label." --when "x > 10"
    knit_done

    _knit_invoke_command "opt_when_cmd1" "--x" "5"
}

@test "optional param constraint: provided when condition false is an error" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    __KNIT_JQ_EXE="jq"

    knit_register knit_empty "opt_when_cmd2" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_optional "label:string" "none" "A label." --when "x > 10"
    knit_done

    run _knit_invoke_command "opt_when_cmd2" "--x" "5" "--label" "hello"
    [ "$status" -eq 1 ]
}

@test "flag constraint: passing flag when condition is false is an error" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    __KNIT_JQ_EXE="jq"

    knit_register knit_empty "flag_when_cmd1" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_flag "verbose" "Verbose mode." --when "x > 10"
    knit_done

    run _knit_invoke_command "flag_when_cmd1" "--x" "5" "--verbose"
    [ "$status" -eq 1 ]
}

@test "flag constraint: flag absent when condition false is OK" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    __KNIT_JQ_EXE="jq"

    knit_register knit_empty "flag_when_cmd2" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_flag "verbose" "Verbose mode." --when "x > 10"
    knit_done

    _knit_invoke_command "flag_when_cmd2" "--x" "5"
}

@test "multi-param condition: both params provided when both conditions true" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    __KNIT_JQ_EXE="jq"

    knit_register knit_empty "multi_when_cmd" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value."
    knit_with_required "z:integer" "Z value." --when "x > 0 and y > 0"
    knit_done

    _knit_invoke_command "multi_when_cmd" "--x" "1" "--y" "2" "--z" "3"
}

@test "multi-param condition: z absent when x <= 0" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    __KNIT_JQ_EXE="jq"

    knit_register knit_empty "multi_when_cmd2" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value."
    knit_with_required "z:integer" "Z value." --when "x > 0 and y > 0"
    knit_done

    _knit_invoke_command "multi_when_cmd2" "--x" "0" "--y" "2"
}

@test "non-boolean constraint expression produces a fatal error" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    __KNIT_JQ_EXE="jq"

    knit_register knit_empty "nonbool_when_cmd" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when "x + 1"
    knit_done

    run _knit_invoke_command "nonbool_when_cmd" "--x" "5" "--y" "3"
    [ "$status" -eq 1 ]
}

@test "knit_with_parameter_set copies --when metadata" {
    knit_define_parameter_set "when_set"
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when "x > 42"
    knit_done

    knit_register knit_empty "pset_when_cmd" "A command."
    knit_with_parameter_set "when_set"
    knit_done

    [ "${_KNIT_CMD_pset_when_cmd_2_y_when}" = ".x > 42" ]
    [ "${_KNIT_CMD_pset_when_cmd_2_y_when_raw}" = "x > 42" ]
}

@test "constraint from parameter set is enforced" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    __KNIT_JQ_EXE="jq"

    knit_define_parameter_set "enforced_set"
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when "x > 42"
    knit_done

    knit_register knit_empty "pset_enforce_cmd" "A command."
    knit_with_parameter_set "enforced_set"
    knit_done

    run _knit_invoke_command "pset_enforce_cmd" "--x" "5" "--y" "10"
    [ "$status" -eq 1 ]
}

# ---------- --when display in --help ----------

@test "help output shows 'when:' annotation for required param with constraint" {
    knit_register knit_empty "help_when_req" "Help test command."
    knit_with_required "x:integer" "The X value."
    knit_with_required "y:integer" "The Y value." --when "x > 42"
    knit_done

    run _knit_invoke_command "help_when_req" "--help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[required, when: x > 42]"* ]]
}

@test "help output shows plain 'required' for required param without constraint" {
    knit_register knit_empty "help_no_when_req" "Help test command."
    knit_with_required "x:integer" "The X value."
    knit_done

    run _knit_invoke_command "help_no_when_req" "--help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[required]"* ]]
    [[ "$output" != *"when:"* ]]
}

@test "help output shows 'when:' annotation for optional param with constraint" {
    knit_register knit_empty "help_when_opt" "Help test command."
    knit_with_required "x:integer" "The X value."
    knit_with_optional "y:integer" "0" "The Y value." --when "x > 0"
    knit_done

    run _knit_invoke_command "help_when_opt" "--help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[default: '0', when: x > 0]"* ]]
}

@test "help output shows 'when:' annotation for flag with constraint" {
    knit_register knit_empty "help_when_flag" "Help test command."
    knit_with_required "x:integer" "The X value."
    knit_with_flag "verbose" "Verbose output." --when "x > 0"
    knit_done

    run _knit_invoke_command "help_when_flag" "--help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[flag, when: x > 0]"* ]]
}

@test "help output shows original (unprocessed) constraint expression" {
    knit_register knit_empty "help_when_raw" "Help test command."
    knit_with_required "x:integer" "The X value."
    knit_with_required "y:integer" "The Y value." --when "x > 42"
    knit_done

    run _knit_invoke_command "help_when_raw" "--help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"x > 42"* ]]
    [[ "$output" != *".x > 42"* ]]
}
