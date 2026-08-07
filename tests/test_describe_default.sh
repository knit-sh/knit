#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
    _register_fixture
}

# Register the same small user command set as the other describe tests, plus a
# command that declares post-"--" extra arguments.
_register_fixture() {
    knit_define_enum "color" "red" "green" "blue"

    knit_register "greet" knit_empty "Say hello to someone."
    knit_with_required "name:string" "Name of the person to greet."
    knit_with_optional "count:integer" "1" "Number of times to greet."
    knit_with_optional "shade:color" "red" "Color of the greeting." \
        --when "count > 1"
    knit_with_flag "capitalize" "Make the output upper-case."
    knit_with_output "greeting:string" "" "The produced greeting."
    knit_with_table
    knit_done

    knit_register "greet:formal" knit_empty "Greet formally."
    knit_done

    knit_register "archive" knit_empty "Archive results."
    knit_with_extra "Files to archive."
    knit_done
}

# Force the color decision deterministically, independent of the test runner's
# terminal, by stubbing the TTY probe.
_force_color()    { _knit_stdout_is_terminal() { return 0; }; }
_force_no_color() { _knit_stdout_is_terminal() { return 1; }; }

# ---------- basic output ----------

@test "describe --format default produces output" {
    run knit describe --format default --only greet
    [ "$status" -eq 0 ]
    [ -n "${output}" ]
}

@test "default is the format used when none is given" {
    _force_no_color
    run knit describe --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'greet\n-----'* ]]
}

# ---------- no-color rendering ----------

@test "no-color: a command title is followed by an hrule" {
    _force_no_color
    run knit describe --format default --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'greet\n-----'* ]]
}

@test "no-color: section headers use hrules" {
    _force_no_color
    run knit describe --format default --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'Options\n  -------'* ]]
    [[ "${output}" == *$'Outputs\n  -------'* ]]
}

@test "sections are indented beneath the command title" {
    _force_no_color
    run knit describe --format default --only greet
    [ "$status" -eq 0 ]
    # Section headers indented two spaces, their entries four.
    [[ "${output}" == *$'\n  Options\n'* ]]
    [[ "${output}" == *$'\n    --name <value>'* ]]
    [[ "${output}" == *$'\n  Outputs\n'* ]]
    [[ "${output}" == *$'\n    greeting'* ]]
}

@test "no-color: output contains no ANSI escape codes" {
    _force_no_color
    run knit describe --format default --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" != *$'\033'* ]]
}

# ---------- color rendering ----------

@test "color: titles and section headers use ANSI escape codes" {
    _force_color
    run knit describe --format default --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'\033[1m'* ]]
    [[ "${output}" == *$'\033[4m'* ]]
}

@test "color: no hrule is emitted under a command title" {
    _force_color
    run knit describe --format default --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" != *$'greet\n-----'* ]]
}

# ---------- content ----------

@test "the kind and user tag are shown for a user command" {
    _force_no_color
    run knit describe --format default --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *'[command, user]  Say hello to someone.'* ]]
}

@test "a framework command is tagged builtin" {
    _force_no_color
    run knit describe --format default --only submit
    [ "$status" -eq 0 ]
    [[ "${output}" == *', builtin]'* ]]
}

@test "required, optional and flag parameters are annotated" {
    _force_no_color
    run knit describe --format default --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *'--name <value>'*'[required]'* ]]
    [[ "${output}" == *"[default: '1']"* ]]
    [[ "${output}" == *'--capitalize'*'[flag]'* ]]
}

@test "an enum parameter shows its allowed values" {
    _force_no_color
    run knit describe --format default --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *'one of: red, green, blue'* ]]
}

@test "a --when constraint is shown" {
    _force_no_color
    run knit describe --format default --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *'when: count > 1'* ]]
}

@test "outputs are listed with type and default" {
    _force_no_color
    run knit describe --format default --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *"[string, default: '']"* ]]
}

@test "a subcommand is printed as its own block by full name" {
    _force_no_color
    run knit describe --format default --only greet --recursive
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'greet formal\n------------'* ]]
}

@test "an extra description is shown when declared" {
    _force_no_color
    run knit describe --format default --only archive
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'Extra\n  -----'* ]]
    [[ "${output}" == *$'\n    Files to archive.'* ]]
}

# ---------- omit flags ----------

@test "--no-input-params omits the Options section" {
    _force_no_color
    run knit describe --format default --only greet --no-input-params
    [ "$status" -eq 0 ]
    [[ "${output}" != *'Options'* ]]
    [[ "${output}" == *$'greet\n-----'* ]]
}

@test "--no-output-params omits the Outputs section" {
    _force_no_color
    run knit describe --format default --only greet --no-output-params
    [ "$status" -eq 0 ]
    [[ "${output}" != *'Outputs'* ]]
    [[ "${output}" == *'Options'* ]]
}
