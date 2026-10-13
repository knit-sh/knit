#!/usr/bin/env bats

# Tests for knit_command_run_before / knit_command_run_after: the by-name twins
# of knit_run_before / knit_run_after. They append a callback to an
# already-registered command's before/after callback list, resolving the command
# by name (hyphen/underscore interchangeable) and fataling on an unknown name.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- before ----------

@test "knit_command_run_before runs the callback before the body" {
    local log="${BATS_TEST_TMPDIR}/order.log"
    knit_register "cb_before" fn_cb_before "Command."
    fn_cb_before() { echo "body" >> "${log}"; }
    knit_done
    fn_cb_before_hook() { echo "before" >> "${log}"; }
    knit_command_run_before "cb_before" fn_cb_before_hook
    _knit_invoke_command "cb_before"
    [ "$(cat "${log}")" = "$(printf 'before\nbody')" ]
}

@test "knit_command_run_before keeps an existing before-callback" {
    knit_register "cb_before_keep" knit_empty "Command."
    fn_cb_keep_first() { echo "first" >> "${BATS_TEST_TMPDIR}/keep.log"; }
    knit_run_before fn_cb_keep_first
    knit_done
    fn_cb_keep_second() { echo "second" >> "${BATS_TEST_TMPDIR}/keep.log"; }
    knit_command_run_before "cb_before_keep" fn_cb_keep_second
    _knit_invoke_command "cb_before_keep"
    [ "$(cat "${BATS_TEST_TMPDIR}/keep.log")" = "$(printf 'first\nsecond')" ]
}

# ---------- after ----------

@test "knit_command_run_after runs the callback after the body" {
    local log="${BATS_TEST_TMPDIR}/after.log"
    knit_register "cb_after" fn_cb_after "Command."
    fn_cb_after() { echo "body" >> "${log}"; }
    knit_done
    fn_cb_after_hook() { echo "after" >> "${log}"; }
    knit_command_run_after "cb_after" fn_cb_after_hook
    _knit_invoke_command "cb_after"
    [ "$(cat "${log}")" = "$(printf 'body\nafter')" ]
}

# ---------- callback arguments are preserved ----------

@test "knit_command_run_after preserves callback arguments verbatim" {
    local marker="${BATS_TEST_TMPDIR}/args.marker"
    knit_register "cb_args" knit_empty "Command."
    knit_done
    fn_cb_args() { printf '%s\n' "$1" > "${marker}"; }
    knit_command_run_after "cb_args" fn_cb_args "hello world"
    _knit_invoke_command "cb_args"
    [ "$(cat "${marker}")" = "hello world" ]
}

# ---------- name resolution ----------

@test "knit_command_run_before resolves a name typed with the other separator" {
    local marker="${BATS_TEST_TMPDIR}/dash.marker"
    knit_register "cb-dash" knit_empty "Command."
    knit_done
    fn_cb_dash() { echo "ran" > "${marker}"; }
    knit_command_run_before "cb_dash" fn_cb_dash
    _knit_invoke_command "cb-dash"
    [ -f "${marker}" ]
}

# ---------- fatal cases ----------

@test "knit_command_run_before is fatal for an unknown command" {
    run knit_command_run_before "no_such_cmd_xyz" some_fn
    [ "$status" -eq 1 ]
}

@test "knit_command_run_after is fatal for an unknown command" {
    run knit_command_run_after "no_such_cmd_xyz" some_fn
    [ "$status" -eq 1 ]
}
