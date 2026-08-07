#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
    _register_fixture
}

# Register the same small user command set as the JSON tests: an enum, a command
# with every parameter group, an output and a table, plus a nested subcommand.
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
}

# Fail (do not skip) a test that needs a YAML parser when yq is not installed:
# CI is expected to provide yq, so a missing parser is an error, not a skip.
_require_yq() {
    if ! command -v yq >/dev/null 2>&1; then
        printf 'yq is required for the describe YAML tests but is not installed\n' >&2
        return 1
    fi
}

# ---------- _knit_describe_yaml_needs_quote ----------

@test "an empty value needs quoting" {
    run _knit_describe_yaml_needs_quote ""
    [ "$status" -eq 0 ]
}

@test "a numeric-looking value needs quoting" {
    run _knit_describe_yaml_needs_quote "1"
    [ "$status" -eq 0 ]
    run _knit_describe_yaml_needs_quote "0.0"
    [ "$status" -eq 0 ]
}

@test "a version-looking value needs quoting" {
    run _knit_describe_yaml_needs_quote "0.1.0"
    [ "$status" -eq 0 ]
}

@test "a boolean/null token needs quoting (case-insensitive)" {
    run _knit_describe_yaml_needs_quote "true";  [ "$status" -eq 0 ]
    run _knit_describe_yaml_needs_quote "No";    [ "$status" -eq 0 ]
    run _knit_describe_yaml_needs_quote "NULL";  [ "$status" -eq 0 ]
}

@test "a colon-space value needs quoting" {
    run _knit_describe_yaml_needs_quote "a: b"
    [ "$status" -eq 0 ]
}

@test "a plain word does not need quoting" {
    run _knit_describe_yaml_needs_quote "red"
    [ "$status" -ne 0 ]
    run _knit_describe_yaml_needs_quote "count > 1"
    [ "$status" -ne 0 ]
    run _knit_describe_yaml_needs_quote "ENV[MC_SAMPLES]"
    [ "$status" -ne 0 ]
}

# ---------- _knit_describe_yaml_scalar ----------

@test "a coerced scalar is double-quoted" {
    local r
    _knit_describe_yaml_scalar r "1" "  "; [ "$r" = '"1"' ]
    _knit_describe_yaml_scalar r "" "  "; [ "$r" = '""' ]
}

@test "a safe scalar is emitted verbatim" {
    local r
    _knit_describe_yaml_scalar r "red" "  "; [ "$r" = "red" ]
}

@test "a multi-line scalar becomes an indented block scalar" {
    local result
    _knit_describe_yaml_scalar result $'line1\nline2' "    "
    [ "${result}" = $'|-\n    line1\n    line2' ]
}

@test "a block scalar round-trips through a YAML parser" {
    _require_yq
    local sc rendered
    _knit_describe_yaml_scalar sc $'multi\nline\nvalue' '  '
    rendered=$(printf 'k: %s\n' "${sc}")
    [ "$(printf '%s' "${rendered}" | yq -c '.k')" \
        = '"multi\nline\nvalue"' ]
}

# ---------- document structure ----------

@test "describe --format yaml produces well-formed YAML" {
    _require_yq
    run knit describe --format yaml
    [ "$status" -eq 0 ]
    printf '%s' "${output}" | yq '.' >/dev/null
}

@test "yaml serializes the same model as the json formatter" {
    _require_yq
    local y j
    # yq transcodes YAML to canonical JSON; jq's JSON is normalized the same way
    # by piping it through yq too (JSON is valid YAML). Sorted, compact output on
    # both sides makes the comparison order-insensitive.
    y=$(_knit_describe_yaml | yq -S -c '.')
    j=$(_knit_describe_json | yq -S -c '.')
    [ "${y}" = "${j}" ]
}

@test "the top-level document carries version, experiment and format_version" {
    run _knit_describe_yaml
    [ "$status" -eq 0 ]
    [[ "${output}" == *"knit_version: \"${KNIT_VERSION}\""* ]]
    [[ "${output}" == *$'\nformat_version: 1\n'* ]]
    [[ "${output}" == *'experiment: '* ]]
}

@test "a numeric-looking default is quoted, keeping it a string" {
    run _knit_describe_yaml
    [ "$status" -eq 0 ]
    [[ "${output}" == *'default: "1"'* ]]
}

@test "an empty default is quoted" {
    run _knit_describe_yaml
    [ "$status" -eq 0 ]
    [[ "${output}" == *'default: ""'* ]]
}

@test "an enum type inlines its values as a flow sequence" {
    run _knit_describe_yaml
    [ "$status" -eq 0 ]
    [[ "${output}" == *'enum: [red, green, blue]'* ]]
}

@test "a --when constraint is emitted as a plain scalar" {
    run _knit_describe_yaml
    [ "$status" -eq 0 ]
    [[ "${output}" == *'when: count > 1'* ]]
}

@test "boolean fields and null values are literals, not strings" {
    run _knit_describe_yaml
    [ "$status" -eq 0 ]
    [[ "${output}" == *'builtin: false'* ]]
    [[ "${output}" == *'dispatcher: null'* ]]
}

@test "a table name and subcommand are reported" {
    run _knit_describe_yaml
    [ "$status" -eq 0 ]
    [[ "${output}" == *'table: greet'* ]]
    [[ "${output}" == *'- name: formal'* ]]
}

# ---------- filters are inherited from the model layer ----------

@test "--exclude-builtins drops framework commands from the yaml" {
    _require_yq
    run knit describe --format yaml --exclude-builtins
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "${output}" | yq -c '[.commands[].name]')" = '["greet"]' ]
}

@test "--no-input-params omits the parameters mapping from the yaml" {
    run knit describe --format yaml --no-input-params
    [ "$status" -eq 0 ]
    [[ "${output}" != *'parameters:'* ]]
}
