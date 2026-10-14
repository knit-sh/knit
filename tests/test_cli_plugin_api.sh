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
