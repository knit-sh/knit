#!/usr/bin/env bats

# Tests for the public decorator-authoring surface a plugin uses to author its
# own decorators. The registration primitives knit_run_before, knit_run_after,
# and knit_push_done_cb are public but exercised in test_cli_register.sh; this
# file covers the pieces added for plugin authors: knit_current_command,
# knit_add_command_note, the per-command marker set/test, knit_reject_if_wrapper,
# and knit_bundle_auto_require.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- knit_current_command ----------

@test "knit_current_command prints the command being registered" {
    knit_register "curcmd" knit_empty "Command."
    [ "$(knit_current_command)" = "curcmd" ]
    knit_done
}

@test "knit_current_command prints the colon form for a nested command" {
    knit_register "curparent" knit_empty "Parent."
    knit_done
    knit_register "curparent:kid" knit_empty "Child."
    [ "$(knit_current_command)" = "curparent:kid" ]
    knit_done
}

@test "knit_current_command fails outside of a registration" {
    run knit_current_command
    [ "$status" -eq 1 ]
}

# ---------- knit_add_command_note ----------

@test "knit_add_command_note appends to the command notes" {
    knit_register "note_cmd" knit_empty "Command."
    knit_add_command_note "Needs a widget."
    local -n notes="_KNIT_CMD_note_cmd_notes"
    [ "${#notes[@]}" -eq 1 ]
    [ "${notes[0]}" = "Needs a widget." ]
    knit_done
}

@test "knit_add_command_note fails outside of a registration" {
    run knit_add_command_note "orphan note"
    [ "$status" -eq 1 ]
}

# ---------- knit_command_set_marker / knit_command_has_marker ----------

@test "a marker is absent until set, then present" {
    knit_register "mk_cmd" knit_empty "Command."
    run knit_command_has_marker "foo"
    [ "$status" -ne 0 ]
    knit_command_set_marker "foo"
    knit_command_has_marker "foo"
    knit_done
}

@test "markers normalize hyphens to underscores" {
    knit_register "mk_hyphen" knit_empty "Command."
    knit_command_set_marker "my-marker"
    knit_command_has_marker "my_marker"
    knit_command_has_marker "my-marker"
    knit_done
}

@test "an invalid marker name is fatal" {
    knit_register "mk_bad" knit_empty "Command."
    run knit_command_set_marker "bad name"
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_command_set_marker fails outside of a registration" {
    run knit_command_set_marker "foo"
    [ "$status" -eq 1 ]
}

@test "knit_command_has_marker fails outside of a registration" {
    run knit_command_has_marker "foo"
    [ "$status" -eq 1 ]
}

# ---------- knit_reject_if_wrapper ----------

@test "knit_reject_if_wrapper is a no-op for a normal command" {
    knit_register "rij_normal" knit_empty "Command."
    knit_reject_if_wrapper "knit_with_whatever"
    knit_done
}

@test "knit_reject_if_wrapper is fatal for a wrapper command" {
    _rij_exec() { :; }
    knit_register_wrapper "rij_wrap" _rij_exec "A wrapper."
    run knit_reject_if_wrapper "knit_with_whatever"
    [ "$status" -eq 1 ]
    knit_done
}

# ---------- knit_bundle_auto_require ----------

@test "knit_bundle_auto_require records a path for the bundle" {
    local before="${#_KNIT_BUNDLE_AUTO_REQUIRES[@]}"
    knit_bundle_auto_require "inputs/data.csv"
    local after="${#_KNIT_BUNDLE_AUTO_REQUIRES[@]}"
    [ "${after}" -eq $(( before + 1 )) ]
    [ "${_KNIT_BUNDLE_AUTO_REQUIRES[$(( after - 1 ))]}" = "inputs/data.csv" ]
}

# ---------- knit_copy_function / knit_rename_function ----------

@test "knit_copy_function duplicates a function and leaves the original" {
    _orig_fn() { printf 'orig:%s\n' "$1"; }
    knit_copy_function _orig_fn _copy_fn
    [ "$(_copy_fn A)" = "orig:A" ]
    # The original is still defined.
    [ "$(_orig_fn B)" = "orig:B" ]
}

@test "knit_copy_function preserves a multi-statement body and arguments" {
    _multi_fn() {
        local x="$1" y="$2"
        printf '%s\n' $(( x + y ))
    }
    knit_copy_function _multi_fn _multi_copy
    [ "$(_multi_copy 2 3)" = "5" ]
}

@test "knit_copy_function is fatal for an undefined function" {
    run knit_copy_function _no_such_function _dest
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a defined function"* ]]
}

@test "knit_rename_function moves a function, removing the original" {
    _ren_fn() { printf 'ren:%s\n' "$1"; }
    knit_rename_function _ren_fn _ren_new
    [ "$(_ren_new Z)" = "ren:Z" ]
    # The original name is gone.
    ! declare -F _ren_fn
}

@test "knit_rename_function enables the decorator-wrapping pattern" {
    # Save a function, then redefine the original to delegate to the saved copy.
    greet() { printf 'hello %s\n' "$1"; }
    knit_rename_function greet _greet_orig
    greet() { printf '[wrapped] '; _greet_orig "$1"; }
    [ "$(greet Ada)" = "[wrapped] hello Ada" ]
}

@test "knit_rename_function is fatal for an undefined function" {
    run knit_rename_function _no_such_function _dest
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a defined function"* ]]
}

# ---------- invocation-args editing ----------

@test "knit_set_parameter injects a value the body sees" {
    _ia_inject() { knit_set_parameter who Zoe; }
    _ia_body() { printf 'who=%s\n' "$(knit_get_parameter who "$@")"; }
    knit_register ia1 _ia_body "demo"
    knit_with_optional "who:string" "default" "who"
    knit_run_before _ia_inject
    knit_done
    run knit ia1
    [ "$output" = "who=Zoe" ]
}

@test "knit_set_parameter replaces an explicitly provided value" {
    _ia_inject() { knit_set_parameter who Zoe; }
    _ia_body() { printf 'who=%s\n' "$(knit_get_parameter who "$@")"; }
    knit_register ia2 _ia_body "demo"
    knit_with_optional "who:string" "default" "who"
    knit_run_before _ia_inject
    knit_done
    run knit ia2 --who Ada
    [ "$output" = "who=Zoe" ]
}

@test "a value injected by knit_set_parameter is recorded in the row" {
    _ia_inject() { knit_set_parameter who Zoe; }
    _ia_body() { :; }
    knit_register ia3 _ia_body "demo"
    knit_with_optional "who:string" "default" "who"
    knit_with_table
    knit_run_before _ia_inject
    knit_done
    knit ia3 --who Ada
    local stored
    stored="$(_knit_sqlite3 "SELECT who FROM ia3;")"
    [ "${stored}" = "Zoe" ]
}

@test "knit_get_invocation_args returns only the invocation args, no fixed-arg offset" {
    _ia_seen=""
    _ia_check() {
        # Registered with two fixed args; the accessor still returns just the args.
        local -a argv
        knit_get_invocation_args argv
        _ia_seen="${argv[*]}"
    }
    _ia_body() { :; }
    knit_register ia4 _ia_body "demo"
    knit_with_optional "who:string" "x" "who"
    knit_run_before _ia_check one two
    knit_done
    knit ia4 --who Bob
    [ "${_ia_seen}" = "--who Bob" ]
}

@test "knit_set_invocation_args replaces the whole argument list" {
    _ia_replace() { knit_set_invocation_args --who Zoe --extra injected; }
    _ia_body() { printf 'who=%s extra=%s\n' \
        "$(knit_get_parameter who "$@")" "$(knit_get_parameter extra "$@")"; }
    knit_register ia5 _ia_body "demo"
    knit_with_optional "who:string" "x" "who"
    knit_with_optional "extra:string" "none" "extra"
    knit_run_before _ia_replace
    knit_done
    run knit ia5 --who Ada
    [ "$output" = "who=Zoe extra=injected" ]
}

@test "a nested command does not corrupt an in-progress edit" {
    _ia_body() { printf 'who=%s\n' "$(knit_get_parameter who "$@")"; }
    knit_register ia_inner _ia_body "inner"
    knit_with_optional "who:string" "x" "who"
    knit_done

    _ia_nest_then_edit() {
        knit ia_inner --who inner > /dev/null    # nested invocation mid-callback
        knit_set_parameter who Outer
    }
    knit_register ia_outer _ia_body "outer"
    knit_with_optional "who:string" "x" "who"
    knit_run_before _ia_nest_then_edit
    knit_done

    run knit ia_outer --who orig
    [ "$output" = "who=Outer" ]
}

@test "knit_set_parameter is fatal for an undeclared parameter" {
    _ia_bad() { knit_set_parameter nope 1; }
    _ia_body() { :; }
    knit_register ia6 _ia_body "demo"
    knit_with_optional "who:string" "x" "who"
    knit_run_before _ia_bad
    knit_done
    run knit ia6
    [ "$status" -ne 0 ]
    [[ "$output" == *'"nope" is not a parameter'* ]]
}

@test "knit_set_parameter is fatal on a type mismatch" {
    _ia_badtype() { knit_set_parameter n notanumber; }
    _ia_body() { :; }
    knit_register ia7 _ia_body "demo"
    knit_with_optional "n:integer" "0" "count"
    knit_run_before _ia_badtype
    knit_done
    run knit ia7
    [ "$status" -ne 0 ]
    [[ "$output" == *'type "integer"'* ]]
}

@test "the editing accessors are fatal outside a before-callback" {
    run knit_set_parameter who x
    [ "$status" -ne 0 ]
    [[ "$output" == *"before-callback"* ]]
    run knit_set_invocation_args --who x
    [ "$status" -ne 0 ]
    [[ "$output" == *"before-callback"* ]]
}
