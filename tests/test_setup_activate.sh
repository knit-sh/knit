#!/usr/bin/env bats

# Tests for the declarative setup activation functions: knit_setup_env_set,
# knit_setup_env_append, knit_setup_env_prepend, knit_setup_env_unset, and
# knit_setup_activate_line. Each is apply-now-and-record: it mutates the current
# build shell AND pushes the equivalent line onto _KNIT_SETUP_ACTIVATE_LINES.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    _test_setup_fn() { :; }
    _KNIT_SETUP_ACTIVATE_LINES=()
    unset KNIT_T_LIST KNIT_T_VAR 2>/dev/null || true
}

teardown() {
    unset KNIT_SETUP_PREFIX KNIT_T_LIST KNIT_T_VAR 2>/dev/null || true
    knit_test_db_teardown
}

# Register a real setup (so its _type marker is "setup") and simulate being
# mid-invocation by pushing it onto the executing-command stack, so the
# activation functions' setup-body guard is satisfied.
_enter_setup_body() {
    local name="${1:-mysetup}"
    knit_register_setup "${name}" "_test_setup_fn" "A test setup."
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "setup:${name}")
    _KNIT_EXECUTING_COMMAND=("${cmd}")
}

# Evaluate a recorded line in a fresh shell where the target list variable
# already holds ${1}, and print the resulting value of that variable. This
# proves the recorded line composes onto the job's own environment.
_compose() {
    local existing="$1" line="$2"
    (
        if [[ -n "${existing}" ]]; then
            export KNIT_T_LIST="${existing}"
        else
            unset KNIT_T_LIST
        fi
        eval "${line}"
        printf '%s' "${KNIT_T_LIST-<UNSET>}"
    )
}

# ---------- knit_setup_env_set ----------

@test "knit_setup_env_set exports the variable in the current shell" {
    _enter_setup_body
    knit_setup_env_set KNIT_T_VAR "hello"
    [ "${KNIT_T_VAR}" = "hello" ]
}

@test "knit_setup_env_set records an export line" {
    _enter_setup_body
    knit_setup_env_set KNIT_T_VAR "hello"
    [ "${_KNIT_SETUP_ACTIVATE_LINES[-1]}" = "export KNIT_T_VAR=hello" ]
}

@test "knit_setup_env_set records a value with spaces using %q quoting" {
    _enter_setup_body
    knit_setup_env_set KNIT_T_VAR "a b"
    local line="${_KNIT_SETUP_ACTIVATE_LINES[-1]}"
    # The recorded line, re-sourced, restores the exact value.
    local got
    got=$( eval "${line}"; printf '%s' "${KNIT_T_VAR}" )
    [ "${got}" = "a b" ]
}

# ---------- knit_setup_env_append ----------

@test "knit_setup_env_append exports the value when the variable was unset" {
    _enter_setup_body
    knit_setup_env_append KNIT_T_LIST "/opt/bin"
    [ "${KNIT_T_LIST}" = "/opt/bin" ]
}

@test "knit_setup_env_append appends with a colon when the variable was set" {
    _enter_setup_body
    export KNIT_T_LIST="/usr/bin"
    knit_setup_env_append KNIT_T_LIST "/opt/bin"
    [ "${KNIT_T_LIST}" = "/usr/bin:/opt/bin" ]
}

@test "knit_setup_env_append recorded line composes onto an existing value" {
    _enter_setup_body
    knit_setup_env_append KNIT_T_LIST "/opt/bin"
    local line="${_KNIT_SETUP_ACTIVATE_LINES[-1]}"
    [ "$(_compose "/x:/y" "${line}")" = "/x:/y:/opt/bin" ]
}

@test "knit_setup_env_append recorded line is empty-safe (no leading colon)" {
    _enter_setup_body
    knit_setup_env_append KNIT_T_LIST "/opt/bin"
    local line="${_KNIT_SETUP_ACTIVATE_LINES[-1]}"
    [ "$(_compose "" "${line}")" = "/opt/bin" ]
}

@test "knit_setup_env_append handles a value with spaces and metacharacters" {
    _enter_setup_body
    knit_setup_env_append KNIT_T_LIST '/a b/$x;`id`'
    local line="${_KNIT_SETUP_ACTIVATE_LINES[-1]}"
    [ "$(_compose "/x" "${line}")" = '/x:/a b/$x;`id`' ]
}

# ---------- knit_setup_env_prepend ----------

@test "knit_setup_env_prepend exports the value when the variable was unset" {
    _enter_setup_body
    knit_setup_env_prepend KNIT_T_LIST "/opt/bin"
    [ "${KNIT_T_LIST}" = "/opt/bin" ]
}

@test "knit_setup_env_prepend prepends with a colon when the variable was set" {
    _enter_setup_body
    export KNIT_T_LIST="/usr/bin"
    knit_setup_env_prepend KNIT_T_LIST "/opt/bin"
    [ "${KNIT_T_LIST}" = "/opt/bin:/usr/bin" ]
}

@test "knit_setup_env_prepend recorded line composes onto an existing value" {
    _enter_setup_body
    knit_setup_env_prepend KNIT_T_LIST "/opt/bin"
    local line="${_KNIT_SETUP_ACTIVATE_LINES[-1]}"
    [ "$(_compose "/x:/y" "${line}")" = "/opt/bin:/x:/y" ]
}

@test "knit_setup_env_prepend recorded line is empty-safe (no trailing colon)" {
    _enter_setup_body
    knit_setup_env_prepend KNIT_T_LIST "/opt/bin"
    local line="${_KNIT_SETUP_ACTIVATE_LINES[-1]}"
    [ "$(_compose "" "${line}")" = "/opt/bin" ]
}

@test "knit_setup_env_prepend handles a value with spaces and metacharacters" {
    _enter_setup_body
    knit_setup_env_prepend KNIT_T_LIST '/a b/$x;`id`'
    local line="${_KNIT_SETUP_ACTIVATE_LINES[-1]}"
    [ "$(_compose "/x" "${line}")" = '/a b/$x;`id`:/x' ]
}

# ---------- knit_setup_env_unset ----------

@test "knit_setup_env_unset unsets the variable in the current shell" {
    _enter_setup_body
    export KNIT_T_VAR="present"
    knit_setup_env_unset KNIT_T_VAR
    [ ! -v KNIT_T_VAR ]
}

@test "knit_setup_env_unset records an unset line" {
    _enter_setup_body
    knit_setup_env_unset KNIT_T_VAR
    [ "${_KNIT_SETUP_ACTIVATE_LINES[-1]}" = "unset KNIT_T_VAR" ]
}

# ---------- knit_setup_activate_line ----------

@test "knit_setup_activate_line runs the line in the current shell now" {
    _enter_setup_body
    knit_setup_activate_line "export KNIT_T_VAR=fromline"
    [ "${KNIT_T_VAR}" = "fromline" ]
}

@test "knit_setup_activate_line records the line verbatim" {
    _enter_setup_body
    knit_setup_activate_line "export KNIT_T_VAR=vialine"
    [ "${_KNIT_SETUP_ACTIVATE_LINES[-1]}" = "export KNIT_T_VAR=vialine" ]
}

@test "knit_setup_activate_line returns the eval exit status" {
    _enter_setup_body
    run knit_setup_activate_line "false"
    [ "${status}" -ne 0 ]
}

# ---------- ordering ----------

@test "declared lines accumulate in call order" {
    _enter_setup_body
    knit_setup_env_set KNIT_T_VAR "one"
    knit_setup_env_append KNIT_T_LIST "/a"
    knit_setup_env_unset KNIT_T_VAR
    [ "${#_KNIT_SETUP_ACTIVATE_LINES[@]}" -eq 3 ]
    [ "${_KNIT_SETUP_ACTIVATE_LINES[0]}" = "export KNIT_T_VAR=one" ]
    [[ "${_KNIT_SETUP_ACTIVATE_LINES[1]}" == export\ KNIT_T_LIST=* ]]
    [ "${_KNIT_SETUP_ACTIVATE_LINES[2]}" = "unset KNIT_T_VAR" ]
}

# ---------- per-invocation reset ----------

@test "the setup before callback clears accumulated activation lines" {
    export KNIT_SETUP_PREFIX="/tmp"
    _KNIT_SETUP_ACTIVATE_LINES=("leftover from a previous invocation")
    _knit_setup_before_cb
    [ "${#_KNIT_SETUP_ACTIVATE_LINES[@]}" -eq 0 ]
}

# ---------- validation and guard ----------

@test "an invalid variable name is fatal" {
    _enter_setup_body
    run knit_setup_env_set "1bad" "x"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Invalid variable name"* ]]
}

@test "a variable name with a hyphen is fatal" {
    _enter_setup_body
    run knit_setup_env_append "BAD-NAME" "x"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Invalid variable name"* ]]
}

@test "knit_setup_env_set outside a setup body is fatal" {
    _KNIT_EXECUTING_COMMAND=()
    run knit_setup_env_set KNIT_T_VAR "x"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be called from within a setup body"* ]]
}

@test "knit_setup_activate_line outside a setup body is fatal" {
    _KNIT_EXECUTING_COMMAND=()
    run knit_setup_activate_line "echo hi"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be called from within a setup body"* ]]
}

@test "activation functions are fatal from within a non-setup command body" {
    _test_fn() { :; }
    knit_register "plaincmd" "_test_fn" "A plain command."
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "plaincmd")
    _KNIT_EXECUTING_COMMAND=("${cmd}")
    run knit_setup_env_set KNIT_T_VAR "x"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be called from within a setup body"* ]]
}
