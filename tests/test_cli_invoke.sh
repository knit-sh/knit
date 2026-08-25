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
    knit_register "ca_cmd" knit_empty "Test."
    knit_with_required "name:string" "A name."
    knit_done
    _knit_check_command_arguments "ca_cmd" "--name" "Alice"
}

@test "_knit_check_command_arguments fails when required arg is missing" {
    knit_register "ca_cmd2" knit_empty "Test."
    knit_with_required "name:string" "A name."
    knit_done
    run _knit_check_command_arguments "ca_cmd2"
    [ "$status" -eq 1 ]
}

@test "_knit_check_command_arguments fails for unexpected argument" {
    knit_register "ca_cmd3" knit_empty "Test."
    knit_done
    run _knit_check_command_arguments "ca_cmd3" "--unknown" "value"
    [ "$status" -eq 1 ]
}

@test "_knit_check_command_arguments fails for extra args when not declared" {
    knit_register "ca_cmd4" knit_empty "Test."
    knit_done
    run _knit_check_command_arguments "ca_cmd4" "--" "extra_arg"
    [ "$status" -eq 1 ]
}

@test "_knit_check_command_arguments passes with extra args when declared" {
    knit_register "ca_cmd5" knit_empty "Test."
    knit_with_extra "Extra arguments."
    knit_done
    _knit_check_command_arguments "ca_cmd5" "--" "extra_arg"
}

@test "_knit_check_command_arguments accepts flags without values" {
    knit_register "ca_cmd6" knit_empty "Test."
    knit_with_flag "verbose" "Verbose mode."
    knit_done
    _knit_check_command_arguments "ca_cmd6" "--verbose"
}

# ---------- _knit_check_command_arguments: type validation ----------

@test "_knit_check_command_arguments accepts a value matching its type" {
    knit_register "ty_ok" knit_empty "Test."
    knit_with_required "count:integer" "A count."
    knit_done
    _knit_check_command_arguments "ty_ok" "--count" "42"
}

@test "_knit_check_command_arguments rejects an integer value that is not an integer" {
    knit_register "ty_int" knit_empty "Test."
    knit_with_required "count:integer" "A count."
    knit_done
    run _knit_check_command_arguments "ty_int" "--count" "abc"
    [ "$status" -ne 0 ]
    [[ "$output" == *"integer"* ]]
}

@test "_knit_check_command_arguments rejects a real value that is not a real" {
    knit_register "ty_real" knit_empty "Test."
    knit_with_required "ratio:real" "A ratio."
    knit_done
    run _knit_check_command_arguments "ty_real" "--ratio" "notanumber"
    [ "$status" -ne 0 ]
    [[ "$output" == *"real"* ]]
}

@test "_knit_check_command_arguments accepts any value for a string parameter" {
    knit_register "ty_str" knit_empty "Test."
    knit_with_required "label:string" "A label."
    knit_done
    _knit_check_command_arguments "ty_str" "--label" "1a-b_?"
}

@test "_knit_check_command_arguments validates the --name=value form" {
    knit_register "ty_inline" knit_empty "Test."
    knit_with_required "count:integer" "A count."
    knit_done
    run _knit_check_command_arguments "ty_inline" "--count=abc"
    [ "$status" -ne 0 ]
    [[ "$output" == *"integer"* ]]
}

@test "_knit_check_command_arguments validates optional parameter values" {
    knit_register "ty_opt" knit_empty "Test."
    knit_with_optional "count:integer" "1" "A count."
    knit_done
    run _knit_check_command_arguments "ty_opt" "--count" "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"integer"* ]]
}

@test "_knit_check_command_arguments accepts a valid enum value" {
    knit_define_enum "ty_color" "red" "green" "blue"
    knit_register "ty_enum_ok" knit_empty "Test."
    knit_with_required "shade:ty_color" "A color."
    knit_done
    _knit_check_command_arguments "ty_enum_ok" "--shade" "green"
}

@test "_knit_check_command_arguments rejects an invalid enum value and lists the choices" {
    knit_define_enum "ty_color2" "red" "green" "blue"
    knit_register "ty_enum_bad" knit_empty "Test."
    knit_with_required "shade:ty_color2" "A color."
    knit_done
    run _knit_check_command_arguments "ty_enum_bad" "--shade" "ultraviolet"
    [ "$status" -ne 0 ]
    [[ "$output" == *"red"* ]]
    [[ "$output" == *"green"* ]]
    [[ "$output" == *"blue"* ]]
}

@test "_knit_invoke_command rejects an ill-typed argument before running the body" {
    knit_register "ty_inv" fn_ty_inv "Test."
    knit_with_required "count:integer" "A count."
    fn_ty_inv() { echo "SHOULD NOT RUN"; }
    knit_done
    run _knit_invoke_command "ty_inv" "--count" "abc"
    [ "$status" -ne 0 ]
    [[ "$output" != *"SHOULD NOT RUN"* ]]
}

# ---------- _knit_expand_command_arguments ----------

@test "_knit_expand_command_arguments fills in optional defaults" {
    knit_register "expa_cmd" knit_empty "Test."
    knit_with_optional "count:integer" "10" "A count."
    knit_done
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd")
    local val
    val=$(knit_get_parameter "count" "${args[@]}")
    [ "$val" = "10" ]
}

@test "_knit_expand_command_arguments does not override provided optional" {
    knit_register "expa_cmd2" knit_empty "Test."
    knit_with_optional "count:integer" "10" "A count."
    knit_done
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd2" "--count" "99")
    local val
    val=$(knit_get_parameter "count" "${args[@]}")
    [ "$val" = "99" ]
}

@test "_knit_expand_command_arguments preserves --key=value for knit_get_parameter" {
    knit_register "expa_cmd3" knit_empty "Test."
    knit_with_required "name:string" "A name."
    knit_done
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd3" "--name=Alice")
    local val
    val=$(knit_get_parameter "name" "${args[@]}")
    [ "$val" = "Alice" ]
}

@test "_knit_expand_command_arguments converts present flag to true" {
    knit_register "expa_cmd4" knit_empty "Test."
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
    knit_register "expa_cmd4h" knit_empty "Test."
    knit_with_flag "no-setup" "No setup."
    knit_done
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd4h" "--no-setup")
    local val
    val=$(knit_get_parameter "no-setup" "${args[@]}")
    [ "$val" = "true" ]
}

@test "_knit_expand_command_arguments converts absent flag to false" {
    knit_register "expa_cmd5" knit_empty "Test."
    knit_with_flag "verbose" "Enable verbose."
    knit_done
    local -a args
    readarray -d '' -t args < <(_knit_expand_command_arguments "expa_cmd5")
    local val
    val=$(knit_get_parameter "verbose" "${args[@]}")
    [ "$val" = "false" ]
}

@test "_knit_expand_command_arguments resolves an ENV[...] default from the environment" {
    knit_register "expa_cmd6" knit_empty "Test."
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
    knit_register "expa_cmd7" knit_empty "Test."
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
    knit_register "expa_cmd8" knit_empty "Test."
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
    knit_register "ic_cmd" fn_ic "Test."
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
    knit_register "ic_cmd_eq" fn_ic_eq "Test."
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
    knit_register "ic_cmd_eq_bad" knit_empty "Test."
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
    knit_register "ic_cmd2" fn_ic2 "Test."
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
    knit_register "par2_cmd" knit_empty "Parent."
    knit_done
    knit_register "par2_cmd:child" fn_child "Child."
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
    knit_register "ic_cmd3" knit_empty "A test command for help."
    knit_with_required "name:string" "A name."
    knit_done
    local result
    result=$(_knit_invoke_command "ic_cmd3" "--help")
    [[ "$result" == *"ic_cmd3 [OPTIONS]"* ]]
    [[ "$result" == *"--name"* ]]
    [[ "$result" == *"--help"* ]]
}

@test "help for an ordinary nested command has no -- in its usage line" {
    knit_register "ic_parent" knit_empty "Parent."
    knit_done
    knit_register "ic_parent:leaf" knit_empty "Leaf."
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
    knit_register "ic_disp" knit_empty "A dispatcher."
    knit_with_optional "root-opt:string" "" "A dispatcher option."
    knit_with_dispatch "target" "A target to dispatch to."
    knit_done
    local result
    result=$(_knit_invoke_command "ic_disp" "--help")
    [[ "$result" == *"ic_disp [OPTIONS] -- <target> [OPTIONS]"* ]]
    [[ "$result" == *"--root-opt"* ]]
}

@test "help for a dispatched subcommand shows parent grammar and options" {
    knit_register "ic_disp2" knit_empty "A dispatcher."
    knit_with_optional "root-opt:string" "" "A dispatcher option."
    knit_with_dispatch "target" "A target to dispatch to."
    knit_done
    knit_register "ic_disp2:leaf" knit_empty "A dispatched leaf."
    knit_with_optional "leaf-opt:string" "" "A leaf option."
    knit_done
    # A dispatched leaf is a specialized kind (a job or app, set by
    # knit_register_job / knit_register_app); an ordinary nested command keeps
    # type "command" and renders with plain nesting instead. Mark the leaf as a
    # job so it renders with the dispatcher grammar.
    printf -v "_KNIT_CMD_$(_knit_command_mangle "ic_disp2:leaf")_type" '%s' 'job'
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

@test "help for an ordinary nested command under a dispatcher uses plain nesting" {
    knit_register "ic_disp3" knit_empty "A dispatcher."
    knit_with_optional "root-opt:string" "" "A dispatcher option."
    knit_with_dispatch "target" "A target to dispatch to."
    knit_done
    # A plain knit_register child keeps type "command" (unlike a job/app), so it
    # is invoked as "parent sub", not dispatched as "parent -- sub" (this is the
    # "submit prepared" / "submit next" case).
    knit_register "ic_disp3:sub" knit_empty "An ordinary nested command."
    knit_with_optional "sub-opt:string" "" "A sub option."
    knit_done
    local result usage_line
    result=$(_knit_invoke_command "ic_disp3" "sub" "--help")
    usage_line=$(printf '%s\n' "$result" | head -1)
    # Ordinary "parent sub" nesting, no "--", and no borrowed parent option block.
    [[ "$usage_line" == *"ic_disp3 sub [OPTIONS]"* ]]
    [[ "$usage_line" != *"--"* ]]
    [[ "$result" == *"--sub-opt"* ]]
    [[ "$result" != *"ic_disp3 options"* ]]
}

@test "_knit_invoke_command runs before and after callbacks in order" {
    knit_register "ic_cmd4" fn_ic4 "Test."
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

@test "_knit_invoke_command aborts the body and returns non-zero when a before-callback fails" {
    knit_register "ic_bfail" fn_ic_bfail "Test."
    _ic_before_fail() { return 1; }
    _knit_run_before _ic_before_fail
    fn_ic_bfail() { echo "body-ran" > "${BATS_TEST_TMPDIR}/ic_bfail.out"; }
    knit_done
    run _knit_invoke_command "ic_bfail"
    [ "$status" -ne 0 ]
    # The body must not have run.
    [ ! -f "${BATS_TEST_TMPDIR}/ic_bfail.out" ]
}

@test "a failing before-callback skips later before-callbacks" {
    knit_register "ic_bfail2" fn_ic_bfail2 "Test."
    _ic_before_fail2() { return 1; }
    _ic_before_after() { echo "second-ran" > "${BATS_TEST_TMPDIR}/ic_bfail2.out"; }
    _knit_run_before _ic_before_fail2
    _knit_run_before _ic_before_after
    fn_ic_bfail2() { :; }
    knit_done
    run _knit_invoke_command "ic_bfail2"
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/ic_bfail2.out" ]
}

@test "_knit_invoke_command does not record a row when a before-callback fails" {
    knit_register "ic_bfail_rec" fn_ic_bfail_rec "Test."
    knit_with_table
    _ic_bfail_rec_before() { return 1; }
    _knit_run_before _ic_bfail_rec_before
    fn_ic_bfail_rec() { :; }
    knit_done
    run _knit_invoke_command "ic_bfail_rec"
    [ "$status" -ne 0 ]
    # The table exists (created before callbacks) but holds no row.
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" "SELECT count(*) FROM 'ic_bfail_rec';")
    [ "$n" -eq 0 ]
}

@test "an after-callback can call knit_output and it lands in the recorded row" {
    _ic_after_out() { knit_output "note" "from-after-cb"; }
    knit_register "ic_ocb" fn_ic_ocb "Test."
    knit_with_table
    knit_with_output "note:string" "" "A note."
    _knit_run_after _ic_after_out
    fn_ic_ocb() { :; }
    knit_done
    _knit_invoke_command "ic_ocb"
    local v
    v=$(sqlite3 "${_KNIT_DATABASE}" "SELECT note FROM 'ic_ocb';")
    [ "$v" = "from-after-cb" ]
}

@test "knit_output from an after-callback is type-checked" {
    _ic_after_bad() { knit_output "num" "not-an-int"; }
    knit_register "ic_ocb2" fn_ic_ocb2 "Test."
    knit_with_table
    knit_with_output "num:integer" "0" "A number."
    _knit_run_after _ic_after_bad
    fn_ic_ocb2() { :; }
    knit_done
    run _knit_invoke_command "ic_ocb2"
    [ "$status" -ne 0 ]
    [[ "$output" == *"expects type"* ]]
}

@test "knit_output from an after-callback on a suppressed rank is discarded with a warning" {
    _ic_after_sup() { knit_output "note" "should-be-dropped"; }
    knit_register "ic_ocb3" fn_ic_ocb3 "Test."
    knit_with_table
    knit_with_output "note:string" "" "A note."
    _knit_run_after _ic_after_sup
    fn_ic_ocb3() { :; }
    knit_done
    _KNIT_RECORDING_SUPPRESSED="1"
    run _knit_invoke_command "ic_ocb3"
    _KNIT_RECORDING_SUPPRESSED=""
    [ "$status" -eq 0 ]
    [[ "$output" == *"discarded"* ]]
}

# ---------- _knit_arg_was_provided / _KNIT_INVOCATION_RAW_ARGS ----------

@test "_knit_arg_was_provided detects a bare flag" {
    _knit_arg_was_provided "verbose" "--verbose"
}

@test "_knit_arg_was_provided detects the --name value form" {
    _knit_arg_was_provided "name" "--name" "World"
}

@test "_knit_arg_was_provided detects the --name=value form" {
    _knit_arg_was_provided "name" "--name=World"
}

@test "_knit_arg_was_provided folds hyphens and underscores both ways" {
    _knit_arg_was_provided "default_nodefile" "--default-nodefile" "hosts"
    _knit_arg_was_provided "default-nodefile" "--default_nodefile" "hosts"
}

@test "_knit_arg_was_provided accepts the option name with a leading --" {
    _knit_arg_was_provided "--name" "--name" "World"
}

@test "_knit_arg_was_provided returns false for an absent option" {
    run _knit_arg_was_provided "missing" "--name" "World"
    [ "$status" -ne 0 ]
}

@test "_knit_arg_was_provided does not treat a value as an option name" {
    # "--name count" must not be read as "--count" being provided.
    run _knit_arg_was_provided "count" "--name" "count"
    [ "$status" -ne 0 ]
}

@test "_knit_arg_was_provided stops scanning at a -- token" {
    run _knit_arg_was_provided "foo" "--" "--foo"
    [ "$status" -ne 0 ]
}

@test "_KNIT_INVOCATION_RAW_ARGS holds only the typed tokens, not injected defaults" {
    knit_register "raw_cmd" fn_raw "Test."
    knit_with_required "name:string" "A name."
    knit_with_optional "count:integer" "10" "A count."
    knit_with_flag "verbose" "Verbose."
    fn_raw() { printf '%s\n' "${_KNIT_INVOCATION_RAW_ARGS[@]}"; }
    knit_done
    run _knit_invoke_command "raw_cmd" "--name" "World"
    [ "$status" -eq 0 ]
    # Exactly the typed tokens: no "--count 10" default, no "--verbose false".
    [ "${lines[0]}" = "--name" ]
    [ "${lines[1]}" = "World" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "_knit_arg_was_provided distinguishes typed options from defaulted ones in a body" {
    knit_register "raw_cmd2" fn_raw2 "Test."
    knit_with_required "name:string" "A name."
    knit_with_optional "count:integer" "10" "A count."
    knit_with_flag "verbose" "Verbose."
    fn_raw2() {
        local -a raw=("${_KNIT_INVOCATION_RAW_ARGS[@]}")
        _knit_arg_was_provided "name" "${raw[@]}" && echo "name:yes" || echo "name:no"
        _knit_arg_was_provided "verbose" "${raw[@]}" && echo "verbose:yes" || echo "verbose:no"
        _knit_arg_was_provided "count" "${raw[@]}" && echo "count:yes" || echo "count:no"
    }
    knit_done
    run _knit_invoke_command "raw_cmd2" "--name=World" "--verbose"
    [ "$status" -eq 0 ]
    [[ "$output" == *"name:yes"* ]]
    [[ "$output" == *"verbose:yes"* ]]
    [[ "$output" == *"count:no"* ]]
}

@test "a nested invocation overwrites _KNIT_INVOCATION_RAW_ARGS (copy-immediately contract)" {
    knit_register "raw_child" fn_raw_child "Child."
    knit_with_required "cval:string" "A child value."
    fn_raw_child() { :; }
    knit_done
    knit_register "raw_parent" fn_raw_parent "Parent."
    knit_with_required "pval:string" "A parent value."
    fn_raw_parent() {
        # Copy immediately, per the contract, before running a nested command.
        local -a mine=("${_KNIT_INVOCATION_RAW_ARGS[@]}")
        _knit_invoke_command "raw_child" "--cval" "kid"
        # The global now reflects the nested call...
        _knit_arg_was_provided "cval" "${_KNIT_INVOCATION_RAW_ARGS[@]}" \
            && echo "global:child" || echo "global:parent"
        # ...but the local copy still holds the parent's typed args.
        _knit_arg_was_provided "pval" "${mine[@]}" && echo "copy:parent" || echo "copy:other"
    }
    knit_done
    run _knit_invoke_command "raw_parent" "--pval" "mom"
    [ "$status" -eq 0 ]
    [[ "$output" == *"global:child"* ]]
    [[ "$output" == *"copy:parent"* ]]
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

