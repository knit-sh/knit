#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
    _register_fixture
}

# Register a small user command set exercising the model: an enum, a command
# with every parameter group, an output and a table, plus a nested subcommand.
_register_fixture() {
    knit_enum "color" "red" "green" "blue"

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

# Extract a value from the JSON in ${output} via a python expression on `d`.
_json() {
    printf '%s' "${output}" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

@test "describe --format json produces well-formed JSON" {
    run _knit_describe --format json
    [ "$status" -eq 0 ]
    printf '%s' "${output}" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "top-level document carries version, experiment and format_version" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "d['knit_version']")" = "${KNIT_VERSION}" ]
    [ "$(_json "d['format_version']")" = "1" ]
    [ "$(_json "'experiment' in d")" = "True" ]
}

@test "a user command is reported as a non-builtin command" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "[c for c in d['commands'] if c['name']=='greet'][0]['builtin']")" = "False" ]
    [ "$(_json "[c for c in d['commands'] if c['name']=='greet'][0]['kind']")" = "command" ]
}

@test "a framework command is reported as builtin" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "[c for c in d['commands'] if c['name']=='submit'][0]['builtin']")" = "True" ]
    [ "$(_json "[c for c in d['commands'] if c['name']=='describe'][0]['builtin']")" = "True" ]
}

@test "a dispatcher command exposes its placeholder" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "[c for c in d['commands'] if c['name']=='submit'][0]['dispatcher']")" = "job" ]
    [ "$(_json "[c for c in d['commands'] if c['name']=='greet'][0]['dispatcher']")" = "None" ]
}

@test "required, optional and flag parameters are grouped" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "[p['name'] for p in [c for c in d['commands'] if c['name']=='greet'][0]['parameters']['required']]")" = "['name']" ]
    [ "$(_json "sorted(p['name'] for p in [c for c in d['commands'] if c['name']=='greet'][0]['parameters']['optional'])")" = "['count', 'shade']" ]
    [ "$(_json "[p['name'] for p in [c for c in d['commands'] if c['name']=='greet'][0]['parameters']['flags']]")" = "['capitalize']" ]
}

@test "an optional parameter carries its raw default" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "[p['default'] for p in [c for c in d['commands'] if c['name']=='greet'][0]['parameters']['optional'] if p['name']=='count'][0]")" = "1" ]
}

@test "an enum-typed parameter inlines its allowed values" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "[p['enum'] for p in [c for c in d['commands'] if c['name']=='greet'][0]['parameters']['optional'] if p['name']=='shade'][0]")" = "['red', 'green', 'blue']" ]
}

@test "a --when constraint is included when present" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "[p['when'] for p in [c for c in d['commands'] if c['name']=='greet'][0]['parameters']['optional'] if p['name']=='shade'][0]")" = "count > 1" ]
}

@test "outputs and table are reported" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "[o['name'] for o in [c for c in d['commands'] if c['name']=='greet'][0]['outputs']]")" = "['greeting']" ]
    [ "$(_json "[c for c in d['commands'] if c['name']=='greet'][0]['table']")" = "greet" ]
}

@test "subcommands are nested under their parent" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "[s['name'] for s in [c for c in d['commands'] if c['name']=='greet'][0]['subcommands']]")" = "['formal']" ]
    [ "$(_json "[c for c in d['commands'] if c['name']=='greet'][0]['subcommands'][0]['path']")" = "['greet', 'formal']" ]
}

@test "user-defined enums are listed, builtins are not" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "d['enums']['color']")" = "['red', 'green', 'blue']" ]
    [ "$(_json "'describe_format' in d['enums']")" = "False" ]
}

@test "hidden commands are excluded" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "[c['name'] for c in d['commands'] if c['name'] in ('_run','__main__')]")" = "[]" ]
}

@test "describe --format json --compact produces well-formed JSON" {
    run knit describe --format json --compact
    [ "$status" -eq 0 ]
    printf '%s' "${output}" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "compact json output is a single line" {
    run knit describe --format json --compact
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | wc -l)" -eq 1 ]
}

@test "compact json packs tokens with no insignificant whitespace" {
    local pretty compact
    pretty=$(knit describe --format json)
    compact=$(knit describe --format json --compact)
    # The pretty form opens indented with a space after the colon; the compact
    # form packs the opening brace and the first key/value together.
    [[ "${pretty}" == $'{\n  "knit_version": "'* ]]
    [[ "${compact}" == '{"knit_version":"'* ]]
}

@test "compact json carries the same content as pretty json" {
    local pretty compact
    pretty=$(knit describe --format json)
    compact=$(knit describe --format json --compact)
    python3 - "${pretty}" "${compact}" <<'PY'
import json, sys
assert json.loads(sys.argv[1]) == json.loads(sys.argv[2])
PY
}

@test "--compact with a non-json format warns and is ignored" {
    run knit describe --format yaml --compact
    [ "$status" -eq 0 ]
    [[ "${output}" == *'--compact'*'--format json'* ]]
    # The yaml document is still emitted (the flag is ignored, not fatal).
    [[ "${output}" == *'knit_version:'* ]]
}

@test "json-compact is no longer a valid format" {
    run knit describe --format json-compact
    [ "$status" -ne 0 ]
}

@test "an unknown format is a fatal error" {
    run _knit_describe --format bogus
    [ "$status" -ne 0 ]
}
