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

# ---------- --when constraints ----------

@test "--when accepted on knit_with_required" {
    knit_register knit_empty "when_req_cmd" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when ".x > 42"
    knit_done
}

@test "--when accepted on knit_with_optional" {
    knit_register knit_empty "when_opt_cmd" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_optional "y:integer" "0" "Y value." --when ".x > 42"
    knit_done
}

@test "--when accepted on knit_with_flag" {
    knit_register knit_empty "when_flg_cmd" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_flag "verbose" "Verbose mode." --when ".x > 42"
    knit_done
}

@test "knit_with_required accepts --when=expr form" {
    knit_register knit_empty "when_req_eq_cmd" "A command."
    knit_with_required "x:integer" "X value."
    run knit_with_required "y:integer" "Y value." --when=".x > 42"
    [ "$status" -eq 0 ]
}

@test "knit_with_required rejects an unknown option" {
    knit_register knit_empty "when_req_bad_cmd" "A command."
    knit_with_required "x:integer" "X value."
    run knit_with_required "y:integer" "Y value." --bogus x
    [ "$status" -ne 0 ]
}

@test "knit_with_optional accepts --when=expr form" {
    knit_register knit_empty "when_opt_eq_cmd" "A command."
    knit_with_required "x:integer" "X value."
    run knit_with_optional "y:integer" "0" "Y value." --when=".x > 42"
    [ "$status" -eq 0 ]
}

@test "knit_with_optional rejects an unknown option" {
    knit_register knit_empty "when_opt_bad_cmd" "A command."
    knit_with_required "x:integer" "X value."
    run knit_with_optional "y:integer" "0" "Y value." --bogus x
    [ "$status" -ne 0 ]
}

@test "knit_with_flag accepts --when=expr form" {
    knit_register knit_empty "when_flg_eq_cmd" "A command."
    knit_with_required "x:integer" "X value."
    run knit_with_flag "verbose" "Verbose mode." --when=".x > 42"
    [ "$status" -eq 0 ]
}

@test "knit_with_flag rejects an unknown option" {
    knit_register knit_empty "when_flg_bad_cmd" "A command."
    knit_with_required "x:integer" "X value."
    run knit_with_flag "verbose" "Verbose mode." --bogus x
    [ "$status" -ne 0 ]
}

@test "--when stores the constraint expression verbatim in metadata variable" {
    knit_register knit_empty "when_meta_cmd" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when ".x > 42"
    knit_done
    [ "${_KNIT_CMD_when_meta_cmd_2_y_when}" = ".x > 42" ]
    [ "${_KNIT_CMD_when_meta_cmd_2_y_when_raw}" = ".x > 42" ]
}

@test "constraint passes: required param provided when condition is true" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    _KNIT_JQ_EXE="jq"

    local captured_x captured_y
    constrained_cmd() {
        captured_x=$(knit_get_parameter "x" "$@")
        captured_y=$(knit_get_parameter "y" "$@")
    }
    knit_register constrained_cmd "constrained_cmd1" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when ".x > 42"
    knit_done

    _knit_invoke_command "constrained_cmd1" "--x" "50" "--y" "10"
    [ "${captured_x}" = "50" ]
    [ "${captured_y}" = "10" ]
}

@test "constraint fails: required param missing when condition is true" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    _KNIT_JQ_EXE="jq"

    knit_register knit_empty "constrained_cmd2" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when ".x > 42"
    knit_done

    run _knit_invoke_command "constrained_cmd2" "--x" "50"
    [ "$status" -eq 1 ]
}

@test "constraint passes: required param absent when condition is false" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    _KNIT_JQ_EXE="jq"

    knit_register knit_empty "constrained_cmd3" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when ".x > 42"
    knit_done

    _knit_invoke_command "constrained_cmd3" "--x" "5"
}

@test "constraint fails: param provided when condition is false" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    _KNIT_JQ_EXE="jq"

    knit_register knit_empty "constrained_cmd4" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when ".x > 42"
    knit_done

    run _knit_invoke_command "constrained_cmd4" "--x" "5" "--y" "10"
    [ "$status" -eq 1 ]
}

@test "optional param constraint: absent when condition false is OK" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    _KNIT_JQ_EXE="jq"

    knit_register knit_empty "opt_when_cmd1" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_optional "label:string" "none" "A label." --when ".x > 10"
    knit_done

    _knit_invoke_command "opt_when_cmd1" "--x" "5"
}

@test "optional param constraint: provided when condition false is an error" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    _KNIT_JQ_EXE="jq"

    knit_register knit_empty "opt_when_cmd2" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_optional "label:string" "none" "A label." --when ".x > 10"
    knit_done

    run _knit_invoke_command "opt_when_cmd2" "--x" "5" "--label" "hello"
    [ "$status" -eq 1 ]
}

@test "flag constraint: passing flag when condition is false is an error" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    _KNIT_JQ_EXE="jq"

    knit_register knit_empty "flag_when_cmd1" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_flag "verbose" "Verbose mode." --when ".x > 10"
    knit_done

    run _knit_invoke_command "flag_when_cmd1" "--x" "5" "--verbose"
    [ "$status" -eq 1 ]
}

@test "flag constraint: flag absent when condition false is OK" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    _KNIT_JQ_EXE="jq"

    knit_register knit_empty "flag_when_cmd2" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_flag "verbose" "Verbose mode." --when ".x > 10"
    knit_done

    _knit_invoke_command "flag_when_cmd2" "--x" "5"
}

@test "multi-param condition: both params provided when both conditions true" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    _KNIT_JQ_EXE="jq"

    knit_register knit_empty "multi_when_cmd" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value."
    knit_with_required "z:integer" "Z value." --when ".x > 0 and .y > 0"
    knit_done

    _knit_invoke_command "multi_when_cmd" "--x" "1" "--y" "2" "--z" "3"
}

@test "multi-param condition: z absent when x <= 0" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    _KNIT_JQ_EXE="jq"

    knit_register knit_empty "multi_when_cmd2" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value."
    knit_with_required "z:integer" "Z value." --when ".x > 0 and .y > 0"
    knit_done

    _knit_invoke_command "multi_when_cmd2" "--x" "0" "--y" "2"
}

@test "non-boolean constraint expression produces a fatal error" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    _KNIT_JQ_EXE="jq"

    knit_register knit_empty "nonbool_when_cmd" "A command."
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when ".x + 1"
    knit_done

    run _knit_invoke_command "nonbool_when_cmd" "--x" "5" "--y" "3"
    [ "$status" -eq 1 ]
}

@test "knit_with_parameter_set copies --when metadata" {
    knit_define_parameter_set "when_set"
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when ".x > 42"
    knit_done

    knit_register knit_empty "pset_when_cmd" "A command."
    knit_with_parameter_set "when_set"
    knit_done

    [ "${_KNIT_CMD_pset_when_cmd_2_y_when}" = ".x > 42" ]
    [ "${_KNIT_CMD_pset_when_cmd_2_y_when_raw}" = ".x > 42" ]
}

@test "constraint from parameter set is enforced" {
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi
    _KNIT_JQ_EXE="jq"

    knit_define_parameter_set "enforced_set"
    knit_with_required "x:integer" "X value."
    knit_with_required "y:integer" "Y value." --when ".x > 42"
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
    knit_with_required "y:integer" "The Y value." --when ".x > 42"
    knit_done

    run _knit_invoke_command "help_when_req" "--help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[required, when: .x > 42]"* ]]
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
    knit_with_optional "y:integer" "0" "The Y value." --when ".x > 0"
    knit_done

    run _knit_invoke_command "help_when_opt" "--help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[default: '0', when: .x > 0]"* ]]
}

@test "help output shows 'when:' annotation for flag with constraint" {
    knit_register knit_empty "help_when_flag" "Help test command."
    knit_with_required "x:integer" "The X value."
    knit_with_flag "verbose" "Verbose output." --when ".x > 0"
    knit_done

    run _knit_invoke_command "help_when_flag" "--help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[flag, when: .x > 0]"* ]]
}

# ---------- knit_check_arguments ----------

@test "knit_check_arguments accepts known options" {
    run knit_check_arguments "stdout stderr" "" --stdout out.txt --stderr err.txt
    [ "$status" -eq 0 ]
}

@test "knit_check_arguments accepts known flags" {
    run knit_check_arguments "title" "cleanup" --cleanup --title hello
    [ "$status" -eq 0 ]
}

@test "knit_check_arguments accepts an empty argument list" {
    run knit_check_arguments "stdout" ""
    [ "$status" -eq 0 ]
}

@test "knit_check_arguments rejects an unknown option" {
    run knit_check_arguments "stdout" "" --stdout out.txt --bogus x
    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected argument"* ]]
}

@test "knit_check_arguments rejects a stray positional argument" {
    run knit_check_arguments "stdout" "" stray --stdout out.txt
    [ "$status" -ne 0 ]
}

@test "knit_check_arguments treats hyphens and underscores as equivalent" {
    run knit_check_arguments "frame-color" "" --frame_color blue
    [ "$status" -eq 0 ]
    run knit_check_arguments "frame_color" "" --frame-color blue
    [ "$status" -eq 0 ]
}

@test "knit_check_arguments does not validate arguments after --" {
    run knit_check_arguments "stdout" "" --stdout out.txt -- --anything goes here
    [ "$status" -eq 0 ]
}

@test "knit_check_arguments does not validate an option value starting with --" {
    run knit_check_arguments "stdout" "" --stdout --weird-value
    [ "$status" -eq 0 ]
}

@test "knit_check_arguments error names the calling function" {
    caller_fn() { knit_check_arguments "stdout" "" --bogus x; }
    run caller_fn
    [ "$status" -ne 0 ]
    [[ "$output" == *"caller_fn:"* ]]
}

@test "knit_check_arguments accepts a known option in --name=value form" {
    run knit_check_arguments "stdout stderr" "" --stdout=out.txt --stderr err.txt
    [ "$status" -eq 0 ]
}

@test "knit_check_arguments rejects an unknown option in --name=value form" {
    run knit_check_arguments "stdout" "" --bogus=x
    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected argument"* ]]
}

@test "knit_check_arguments does not consume the next token for --name=value" {
    # If the inline value were not recognized, "extra" would be swallowed as the
    # value of --stdout and validation would wrongly pass.
    run knit_check_arguments "stdout" "" --stdout=out.txt extra
    [ "$status" -ne 0 ]
}
