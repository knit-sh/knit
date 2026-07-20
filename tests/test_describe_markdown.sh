#!/usr/bin/env bats

setup() {
    source knit.sh
    _register_fixture
}

# Register the same small user command set as the other describe tests, plus a
# command declaring post-"--" extra arguments and a program description.
_register_fixture() {
    knit_set_program_description "Demo experiment."
    knit_define_enum "color" "red" "green" "blue"

    knit_register knit_empty "greet" "Say hello to someone."
    knit_with_required "name:string" "Name of the person to greet."
    knit_with_optional "count:integer" "1" "Number of times to greet."
    knit_with_optional "shade:color" "red" "Color of the greeting." \
        --when "count > 1"
    knit_with_flag "capitalize" "Make the output upper-case."
    knit_with_output "greeting:string" "" "The produced greeting."
    knit_with_table
    knit_done

    knit_register knit_empty "greet:formal" "Greet formally."
    knit_done

    knit_register knit_empty "archive" "Archive results."
    knit_with_extra "Files to archive."
    knit_done
}

# ---------- document structure ----------

@test "describe --format markdown produces output" {
    run knit describe --format markdown --only greet
    [ "$status" -eq 0 ]
    [ -n "${output}" ]
}

@test "the document opens with an h1 title from the program description" {
    run knit describe --format markdown --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'# Demo experiment.\n'* ]]
}

@test "the title falls back to the script name when no description is set" {
    _KNIT_CMD___main___description=""
    run knit describe --format markdown --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == "# ${KNIT_SCRIPT_NAME}"* ]]
}

@test "a single '## Commands' wrapper section is emitted" {
    run knit describe --format markdown --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'\n## Commands\n'* ]]
}

@test "each command is an h3 titled by its full name" {
    run knit describe --format markdown --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'\n### greet\n'* ]]
}

@test "a subcommand stays at h3 regardless of depth (full name)" {
    run knit describe --format markdown --only greet --recursive
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'\n### greet formal\n'* ]]
    # It must not be pushed to a deeper heading level by its depth.
    [[ "${output}" != *'#### greet formal'* ]]
}

@test "the intro line carries the kind and builtin/user note" {
    run knit describe --format markdown --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *'*command, user* — Say hello to someone.'* ]]
}

@test "a framework command is noted as builtin" {
    run knit describe --format markdown --only submit
    [ "$status" -eq 0 ]
    [[ "${output}" == *', builtin* —'* ]]
}

# ---------- parameters table ----------

@test "the Parameters sub-section is an h4 with a table header" {
    run knit describe --format markdown --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'#### Parameters\n'* ]]
    [[ "${output}" == *'| Name | Kind | Type | Default | Constraints | Description |'* ]]
    [[ "${output}" == *'|------|------|------|---------|-------------|-------------|'* ]]
}

@test "required, optional and flag rows carry the right kind and default" {
    run knit describe --format markdown --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *'| `name` | required | string | — | — | Name of the person to greet. |'* ]]
    [[ "${output}" == *'| `count` | optional | integer | `1` |'* ]]
    [[ "${output}" == *'| `capitalize` | flag | boolean | — |'* ]]
}

@test "an enum parameter inlines its values and a when clause in Constraints" {
    run knit describe --format markdown --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *'one of: blue, green, red; when: `count > 1`'* ]]
}

# ---------- outputs table ----------

@test "the Outputs sub-section is an h4 table with a blank empty default" {
    run knit describe --format markdown --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'#### Outputs\n'* ]]
    [[ "${output}" == *'| Name | Type | Default | Description |'* ]]
    [[ "${output}" == *'| `greeting` | string |  | The produced greeting. |'* ]]
}

# ---------- extra ----------

@test "a post-'--' extra is rendered as an italic line" {
    run knit describe --format markdown --only archive
    [ "$status" -eq 0 ]
    [[ "${output}" == *'*Extra: Files to archive.*'* ]]
}

# ---------- empty sections ----------

@test "a command with no parameters or outputs shows '*None.*'" {
    run knit describe --format markdown --only greet --recursive
    [ "$status" -eq 0 ]
    # greet:formal declares neither parameters nor outputs.
    [[ "${output}" == *$'### greet formal\n'* ]]
    [[ "${output}" == *'*None.*'* ]]
}

# ---------- omit flags ----------

@test "--no-input-params omits the Parameters sub-section" {
    run knit describe --format markdown --only greet --no-input-params
    [ "$status" -eq 0 ]
    [[ "${output}" != *'#### Parameters'* ]]
    [[ "${output}" == *'#### Outputs'* ]]
}

@test "--no-output-params omits the Outputs sub-section" {
    run knit describe --format markdown --only greet --no-output-params
    [ "$status" -eq 0 ]
    [[ "${output}" != *'#### Outputs'* ]]
    [[ "${output}" == *'#### Parameters'* ]]
}

# ---------- table-cell escaping ----------

@test "a pipe in a description is escaped so the table row is preserved" {
    knit_register knit_empty "piped" "Uses a | pipe."
    knit_with_required "arg:string" "First | second choice."
    knit_done
    run knit describe --format markdown --only piped
    [ "$status" -eq 0 ]
    [[ "${output}" == *'First \| second choice.'* ]]
}
