#!/usr/bin/env bats

setup() {
    source knit.sh
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

# ---------- __knit_check_command_arguments ----------

@test "__knit_check_command_arguments passes when all required args are present" {
    knit_register knit_empty "ca_cmd" "Test."
    knit_with_required "name:string" "A name."
    knit_done
    __knit_check_command_arguments "ca_cmd" "--name" "Alice"
}

@test "__knit_check_command_arguments fails when required arg is missing" {
    knit_register knit_empty "ca_cmd2" "Test."
    knit_with_required "name:string" "A name."
    knit_done
    run __knit_check_command_arguments "ca_cmd2"
    [ "$status" -eq 1 ]
}

@test "__knit_check_command_arguments fails for unexpected argument" {
    knit_register knit_empty "ca_cmd3" "Test."
    knit_done
    run __knit_check_command_arguments "ca_cmd3" "--unknown" "value"
    [ "$status" -eq 1 ]
}

@test "__knit_check_command_arguments fails for extra args when not declared" {
    knit_register knit_empty "ca_cmd4" "Test."
    knit_done
    run __knit_check_command_arguments "ca_cmd4" "--" "extra_arg"
    [ "$status" -eq 1 ]
}

@test "__knit_check_command_arguments passes with extra args when declared" {
    knit_register knit_empty "ca_cmd5" "Test."
    knit_with_extra "Extra arguments."
    knit_done
    __knit_check_command_arguments "ca_cmd5" "--" "extra_arg"
}

@test "__knit_check_command_arguments accepts flags without values" {
    knit_register knit_empty "ca_cmd6" "Test."
    knit_with_flag "verbose" "Verbose mode."
    knit_done
    __knit_check_command_arguments "ca_cmd6" "--verbose"
}

# ---------- __knit_expand_command_arguments ----------

@test "__knit_expand_command_arguments fills in optional defaults" {
    knit_register knit_empty "expa_cmd" "Test."
    knit_with_optional "count:integer" "10" "A count."
    knit_done
    local result val
    result=$(__knit_expand_command_arguments "expa_cmd")
    eval "local args=(${result})"
    val=$(knit_get_parameter "count" "${args[@]}")
    [ "$val" = "10" ]
}

@test "__knit_expand_command_arguments does not override provided optional" {
    knit_register knit_empty "expa_cmd2" "Test."
    knit_with_optional "count:integer" "10" "A count."
    knit_done
    local result val
    result=$(__knit_expand_command_arguments "expa_cmd2" "--count" "99")
    eval "local args=(${result})"
    val=$(knit_get_parameter "count" "${args[@]}")
    [ "$val" = "99" ]
}

@test "__knit_expand_command_arguments expands --key=value syntax" {
    knit_register knit_empty "expa_cmd3" "Test."
    knit_with_required "name:string" "A name."
    knit_done
    local result val
    result=$(__knit_expand_command_arguments "expa_cmd3" "--name=Alice")
    eval "local args=(${result})"
    val=$(knit_get_parameter "name" "${args[@]}")
    [ "$val" = "Alice" ]
}

@test "__knit_expand_command_arguments converts present flag to true" {
    knit_register knit_empty "expa_cmd4" "Test."
    knit_with_flag "verbose" "Enable verbose."
    knit_done
    local result val
    result=$(__knit_expand_command_arguments "expa_cmd4" "--verbose")
    eval "local args=(${result})"
    val=$(knit_get_parameter "verbose" "${args[@]}")
    [ "$val" = "true" ]
}

@test "__knit_expand_command_arguments converts absent flag to false" {
    knit_register knit_empty "expa_cmd5" "Test."
    knit_with_flag "verbose" "Enable verbose."
    knit_done
    local result val
    result=$(__knit_expand_command_arguments "expa_cmd5")
    eval "local args=(${result})"
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
