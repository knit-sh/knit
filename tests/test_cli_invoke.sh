#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
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

# ---------- _knit_check_command_arguments: type validation ----------

@test "_knit_check_command_arguments accepts a value matching its type" {
    knit_register knit_empty "ty_ok" "Test."
    knit_with_required "count:integer" "A count."
    knit_done
    _knit_check_command_arguments "ty_ok" "--count" "42"
}

@test "_knit_check_command_arguments rejects an integer value that is not an integer" {
    knit_register knit_empty "ty_int" "Test."
    knit_with_required "count:integer" "A count."
    knit_done
    run _knit_check_command_arguments "ty_int" "--count" "abc"
    [ "$status" -ne 0 ]
    [[ "$output" == *"integer"* ]]
}

@test "_knit_check_command_arguments rejects a real value that is not a real" {
    knit_register knit_empty "ty_real" "Test."
    knit_with_required "ratio:real" "A ratio."
    knit_done
    run _knit_check_command_arguments "ty_real" "--ratio" "notanumber"
    [ "$status" -ne 0 ]
    [[ "$output" == *"real"* ]]
}

@test "_knit_check_command_arguments accepts any value for a string parameter" {
    knit_register knit_empty "ty_str" "Test."
    knit_with_required "label:string" "A label."
    knit_done
    _knit_check_command_arguments "ty_str" "--label" "1a-b_?"
}

@test "_knit_check_command_arguments validates the --name=value form" {
    knit_register knit_empty "ty_inline" "Test."
    knit_with_required "count:integer" "A count."
    knit_done
    run _knit_check_command_arguments "ty_inline" "--count=abc"
    [ "$status" -ne 0 ]
    [[ "$output" == *"integer"* ]]
}

@test "_knit_check_command_arguments validates optional parameter values" {
    knit_register knit_empty "ty_opt" "Test."
    knit_with_optional "count:integer" "1" "A count."
    knit_done
    run _knit_check_command_arguments "ty_opt" "--count" "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"integer"* ]]
}

@test "_knit_check_command_arguments accepts a valid enum value" {
    knit_define_enum "ty_color" "red" "green" "blue"
    knit_register knit_empty "ty_enum_ok" "Test."
    knit_with_required "shade:ty_color" "A color."
    knit_done
    _knit_check_command_arguments "ty_enum_ok" "--shade" "green"
}

@test "_knit_check_command_arguments rejects an invalid enum value and lists the choices" {
    knit_define_enum "ty_color2" "red" "green" "blue"
    knit_register knit_empty "ty_enum_bad" "Test."
    knit_with_required "shade:ty_color2" "A color."
    knit_done
    run _knit_check_command_arguments "ty_enum_bad" "--shade" "ultraviolet"
    [ "$status" -ne 0 ]
    [[ "$output" == *"red"* ]]
    [[ "$output" == *"green"* ]]
    [[ "$output" == *"blue"* ]]
}

@test "_knit_invoke_command rejects an ill-typed argument before running the body" {
    knit_register fn_ty_inv "ty_inv" "Test."
    knit_with_required "count:integer" "A count."
    fn_ty_inv() { echo "SHOULD NOT RUN"; }
    knit_done
    run _knit_invoke_command "ty_inv" "--count" "abc"
    [ "$status" -ne 0 ]
    [[ "$output" != *"SHOULD NOT RUN"* ]]
}

# ---------- _knit_expand_command_arguments ----------

@test "_knit_expand_command_arguments fills in optional defaults" {
    knit_register knit_empty "expa_cmd" "Test."
    knit_with_optional "count:integer" "10" "A count."
    knit_done
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd")
    local val
    val=$(knit_get_parameter "count" "${args[@]}")
    [ "$val" = "10" ]
}

@test "_knit_expand_command_arguments does not override provided optional" {
    knit_register knit_empty "expa_cmd2" "Test."
    knit_with_optional "count:integer" "10" "A count."
    knit_done
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd2" "--count" "99")
    local val
    val=$(knit_get_parameter "count" "${args[@]}")
    [ "$val" = "99" ]
}

@test "_knit_expand_command_arguments preserves --key=value for knit_get_parameter" {
    knit_register knit_empty "expa_cmd3" "Test."
    knit_with_required "name:string" "A name."
    knit_done
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd3" "--name=Alice")
    local val
    val=$(knit_get_parameter "name" "${args[@]}")
    [ "$val" = "Alice" ]
}

@test "_knit_expand_command_arguments converts present flag to true" {
    knit_register knit_empty "expa_cmd4" "Test."
    knit_with_flag "verbose" "Enable verbose."
    knit_done
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd4" "--verbose")
    local val
    val=$(knit_get_parameter "verbose" "${args[@]}")
    [ "$val" = "true" ]
}

@test "_knit_expand_command_arguments converts a hyphenated flag to true" {
    # A flag registered with a hyphen is stored underscored ("no_setup"); the
    # user still writes it with a hyphen. Expansion must insert "true" after the
    # hyphenated token, not only after the underscored form.
    knit_register knit_empty "expa_cmd4h" "Test."
    knit_with_flag "no-setup" "No setup."
    knit_done
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd4h" "--no-setup")
    local val
    val=$(knit_get_parameter "no-setup" "${args[@]}")
    [ "$val" = "true" ]
}

@test "_knit_expand_command_arguments converts absent flag to false" {
    knit_register knit_empty "expa_cmd5" "Test."
    knit_with_flag "verbose" "Enable verbose."
    knit_done
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd5")
    local val
    val=$(knit_get_parameter "verbose" "${args[@]}")
    [ "$val" = "false" ]
}

@test "_knit_expand_command_arguments resolves an ENV[...] default from the environment" {
    knit_register knit_empty "expa_cmd6" "Test."
    knit_with_optional "seed:integer" "ENV[_KNIT_TEST_SEED]" "A seed."
    knit_done
    export _KNIT_TEST_SEED="7"
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd6")
    local val
    val=$(knit_get_parameter "seed" "${args[@]}")
    [ "$val" = "7" ]
    unset _KNIT_TEST_SEED
}

@test "_knit_expand_command_arguments lets an explicit value override an ENV[...] default" {
    knit_register knit_empty "expa_cmd7" "Test."
    knit_with_optional "seed:integer" "ENV[_KNIT_TEST_SEED]" "A seed."
    knit_done
    export _KNIT_TEST_SEED="7"
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd7" "--seed" "99")
    local val
    val=$(knit_get_parameter "seed" "${args[@]}")
    [ "$val" = "99" ]
    unset _KNIT_TEST_SEED
}

@test "_knit_expand_command_arguments resolves an unset ENV[...] default to empty" {
    knit_register knit_empty "expa_cmd8" "Test."
    knit_with_optional "seed:string" "ENV[_KNIT_TEST_UNSET_SEED]" "A seed."
    knit_done
    unset _KNIT_TEST_UNSET_SEED
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd8")
    local val
    val=$(knit_get_parameter "seed" "${args[@]}")
    [ -z "$val" ]
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

@test "_knit_invoke_command accepts the --name=value form" {
    knit_register fn_ic_eq "ic_cmd_eq" "Test."
    knit_with_required "name:string" "A name."
    fn_ic_eq() {
        local name
        name=$(knit_get_parameter "name" "$@")
        echo "Hello, ${name}!"
    }
    knit_done
    local result
    result=$(_knit_invoke_command "ic_cmd_eq" "--name=World")
    [ "$result" = "Hello, World!" ]
}

@test "_knit_invoke_command rejects an unknown --name=value option" {
    knit_register knit_empty "ic_cmd_eq_bad" "Test."
    knit_with_required "name:string" "A name."
    knit_done
    run _knit_invoke_command "ic_cmd_eq_bad" "--name=World" "--bogus=x"
    [ "$status" -ne 0 ]
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
    [[ "$result" == *"ic_cmd3 [OPTIONS]"* ]]
    [[ "$result" == *"--name"* ]]
    [[ "$result" == *"--help"* ]]
}

@test "help for an ordinary nested command has no -- in its usage line" {
    knit_register knit_empty "ic_parent" "Parent."
    knit_done
    knit_register knit_empty "ic_parent:leaf" "Leaf."
    knit_with_required "name:string" "A name."
    knit_done
    local result usage_line
    result=$(_knit_invoke_command "ic_parent" "leaf" "--help")
    [[ "$result" == *"ic_parent leaf [OPTIONS]"* ]]
    # The usage line uses ordinary "parent child" nesting, not "-- child".
    usage_line=$(printf '%s\n' "$result" | head -1)
    [[ "$usage_line" != *"--"* ]]
}

@test "help for a dispatcher shows the -- placeholder in its usage line" {
    knit_register knit_empty "ic_disp" "A dispatcher."
    knit_with_optional "root-opt:string" "" "A dispatcher option."
    knit_with_dispatch "target" "A target to dispatch to."
    knit_done
    local result
    result=$(_knit_invoke_command "ic_disp" "--help")
    [[ "$result" == *"ic_disp [OPTIONS] -- <target> [OPTIONS]"* ]]
    [[ "$result" == *"--root-opt"* ]]
}

@test "help for a dispatched subcommand shows parent grammar and options" {
    knit_register knit_empty "ic_disp2" "A dispatcher."
    knit_with_optional "root-opt:string" "" "A dispatcher option."
    knit_with_dispatch "target" "A target to dispatch to."
    knit_done
    knit_register knit_empty "ic_disp2:leaf" "A dispatched leaf."
    knit_with_optional "leaf-opt:string" "" "A leaf option."
    knit_done
    local result
    result=$(_knit_invoke_command "ic_disp2" "leaf" "--help")
    # Usage reflects the "parent [OPTIONS] -- leaf [OPTIONS]" grammar.
    [[ "$result" == *"ic_disp2 [OPTIONS] -- leaf [OPTIONS]"* ]]
    # The leaf's own option and the borrowed parent option both appear.
    [[ "$result" == *"--leaf-opt"* ]]
    [[ "$result" == *"ic_disp2 options"* ]]
    [[ "$result" == *"--root-opt"* ]]
    # Exactly one --help line (the leaf's; the parent block omits it).
    [ "$(printf '%s\n' "$result" | grep -c -- '--help')" -eq 1 ]
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

