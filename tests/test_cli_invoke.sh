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

@test "__knit_expand_command_arguments preserves --key=value for knit_get_parameter" {
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

