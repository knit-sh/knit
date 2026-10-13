#!/usr/bin/env bats

# Tests for knit_extend / @extend (reopening an already-closed registration) and
# the enum-edit decorator knit_enum_value. A command, setup, job, app, or
# wrapper reopens into a command context (ordinary decorators append); an enum
# reopens into an enum-edit context (knit_enum_value appends values).

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- extend a command: add an optional ----------

@test "knit_extend adds an optional to an already-registered command" {
    knit_register "ext_opt" knit_empty "Command."
    knit_done
    knit_extend "ext_opt"
    knit_with_optional "greeting:string" "Hello" "A greeting."
    knit_done
    _knit_set_find "_KNIT_CMD_ext_opt_optional" "greeting"
}

@test "an optional added via knit_extend injects its default at invocation" {
    knit_register "ext_default" fn_ext_default "Command."
    knit_with_required "name:string" "A name."
    fn_ext_default() {
        local greeting name
        greeting=$(knit_get_parameter "greeting" "$@")
        name=$(knit_get_parameter "name" "$@")
        echo "${greeting}, ${name}!"
    }
    knit_done
    knit_extend "ext_default"
    knit_with_optional "greeting:string" "Hello" "A greeting."
    knit_done
    local result
    result=$(_knit_invoke_command "ext_default" "--name" "World")
    [ "$result" = "Hello, World!" ]
}

# ---------- extend a command: hook the body ----------

@test "knit_extend can hook the body with knit_run_after" {
    knit_register "ext_hook" knit_empty "Command."
    knit_done
    local marker="${BATS_TEST_TMPDIR}/ext_hook.marker"
    fn_ext_hook_after() { echo "ran" > "${marker}"; }
    knit_extend "ext_hook"
    knit_run_after fn_ext_hook_after
    knit_done
    _knit_invoke_command "ext_hook"
    [ -f "${marker}" ]
    [ "$(cat "${marker}")" = "ran" ]
}

# ---------- extend a command: resolve a hyphenated name ----------

@test "knit_extend resolves a name typed with the other separator" {
    knit_register "ext-dash" knit_empty "Command."
    knit_done
    knit_extend "ext_dash"
    knit_with_flag "verbose" "Verbose."
    knit_done
    _knit_set_find "_KNIT_CMD_ext_dash_flags" "verbose"
}

# ---------- extend an enum ----------

@test "knit_extend adds a value to an existing enum and keeps the old ones" {
    knit_enum "ext_color" "red" "green"
    knit_extend "ext_color"
    knit_enum_value "blue"
    knit_done
    [ "$(knit_enum_values "ext_color" ",")" = "red,green,blue" ]
}

@test "knit_enum_value adds several values at once" {
    knit_enum "ext_shape" "circle"
    knit_extend "ext_shape"
    knit_enum_value "square" "triangle"
    knit_done
    [ "$(knit_enum_values "ext_shape" ",")" = "circle,square,triangle" ]
}

@test "knit_enum_value ignores a duplicate value" {
    knit_enum "ext_dup" "a" "b"
    knit_extend "ext_dup"
    knit_enum_value "b" "c"
    knit_done
    [ "$(knit_enum_values "ext_dup" ",")" = "a,b,c" ]
}

@test "knit_enum_value is fatal outside an enum-edit context" {
    run knit_enum_value "orphan"
    [ "$status" -eq 1 ]
}

# ---------- fatal cases ----------

@test "knit_extend is fatal for a name that was never registered" {
    run knit_extend "never_registered_xyz"
    [ "$status" -eq 1 ]
}

# ---------- the @extend shorthand ----------

@test "@extend reopens a command for extension" {
    knit_register "ext_sh" knit_empty "Command."
    knit_done
    @extend "ext_sh"
    knit_with_flag "quiet" "Quiet."
    knit_done
    _knit_set_find "_KNIT_CMD_ext_sh_flags" "quiet"
}
