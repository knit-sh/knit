#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
    _register_fixture
}

# A command that declares each kind of marked output: a value result
# (--result on an ordinary output), a plain output, an artifact that is also a
# result, and an artifact that is not. A second, plain command has no artifact,
# so its Artifacts section must not appear.
_register_fixture() {
    knit_register "tabulate" knit_empty "Tabulate results."
    knit_with_output "pi:real" "0" "Estimated value of pi." --result
    knit_with_output "scratch:string" "" "Intermediate note."
    knit_with_output_artifact "table:file" "Computed dataset (CSV)." --result
    knit_with_output_artifact "dump:file" "Environment capture."
    knit_done

    knit_register "greet" knit_empty "Say hello."
    knit_with_output "msg:string" "" "The message."
    knit_done
}

# Extract a value from the JSON in ${output} via a python expression on `d`.
_json() {
    printf '%s' "${output}" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

# The tabulate command object from the parsed JSON, as a python expression.
_TAB="[c for c in d['commands'] if c['name']=='tabulate'][0]"

# One output object of tabulate by name, as a python expression.
_out() {
    printf "[o for o in ${_TAB}['outputs'] if o['name']=='%s'][0]" "$1"
}

# One artifact object of tabulate by name, as a python expression.
_art() {
    printf "[a for a in ${_TAB}['artifacts'] if a['name']=='%s'][0]" "$1"
}

# Extract a value from the YAML in ${output} via a python expression on `d`.
_yaml() {
    printf '%s' "${output}" | python3 -c "import yaml,sys; d=yaml.safe_load(sys.stdin); print($1)"
}

# ---------- JSON ----------

@test "json: a value output with --result reports result true" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "$(_out pi)['result']")" = "True" ]
}

@test "json: a plain output reports result false" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "$(_out scratch)['result']")" = "False" ]
}

@test "json: an artifact appears in the artifacts array, not the outputs array" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    # No artifact leaks into the outputs array (it is not an output column).
    [ "$(_json "'table' in [o['name'] for o in ${_TAB}['outputs']]")" = "False" ]
    [ "$(_json "'dump' in [o['name'] for o in ${_TAB}['outputs']]")" = "False" ]
    # Both artifacts are listed in the artifacts array.
    [ "$(_json "sorted(a['name'] for a in ${_TAB}['artifacts'])")" \
        = "['dump', 'table']" ]
}

@test "json: an artifact carries its type, description, and result mark" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "$(_art table)['type']")" = "file" ]
    [ "$(_json "$(_art table)['description']")" = "Computed dataset (CSV)." ]
    [ "$(_json "$(_art table)['result']")" = "True" ]
    [ "$(_json "$(_art dump)['result']")" = "False" ]
    # An artifact is a produced entity, not an output column, so it has no default.
    [ "$(_json "'default' in $(_art table)")" = "False" ]
}

@test "json: a command with no artifact reports an empty artifacts array" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    local greet="[c for c in d['commands'] if c['name']=='greet'][0]"
    [ "$(_json "${greet}['artifacts']")" = "[]" ]
}

@test "json: compact form carries the same artifacts array" {
    run _knit_describe_json_compact
    [ "$status" -eq 0 ]
    [ "$(_json "$(_art table)['result']")" = "True" ]
    [ "$(_json "sorted(a['name'] for a in ${_TAB}['artifacts'])")" \
        = "['dump', 'table']" ]
}

# ---------- YAML ----------

@test "yaml: result marks and the artifacts sequence mirror the JSON model" {
    run _knit_describe_yaml
    [ "$status" -eq 0 ]
    local tab="[c for c in d['commands'] if c['name']=='tabulate'][0]"
    local pi="[o for o in ${tab}['outputs'] if o['name']=='pi'][0]"
    local table="[a for a in ${tab}['artifacts'] if a['name']=='table'][0]"
    local dump="[a for a in ${tab}['artifacts'] if a['name']=='dump'][0]"
    # A value output stays in outputs with its result mark.
    [ "$(_yaml "${pi}['result']")" = "True" ]
    [ "$(_yaml "'table' in [o['name'] for o in ${tab}['outputs']]")" = "False" ]
    # Artifacts live in the artifacts sequence, carrying their result mark.
    [ "$(_yaml "${table}['type']")" = "file" ]
    [ "$(_yaml "${table}['result']")" = "True" ]
    [ "$(_yaml "${dump}['result']")" = "False" ]
}

# ---------- default (human) ----------

@test "default: a value result carries the 'result' tag in its bracket" {
    run knit describe --format default --only tabulate --no-color
    [ "$status" -eq 0 ]
    [[ "${output}" == *"pi"*"[real, default: '0', result]"* ]]
}

@test "default: a plain output has no 'result' tag" {
    run knit describe --format default --only tabulate --no-color
    [ "$status" -eq 0 ]
    local line
    line=$(printf '%s\n' "${output}" | grep -E '^ +scratch ')
    [[ "${line}" == *"[string, default: '']"* ]]
    [[ "${line}" != *"result"* ]]
}

@test "default: artifacts appear in an Artifacts section, not in Outputs" {
    run knit describe --format default --only tabulate --no-color
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'Artifacts\n  ---------'* ]]
    # The Outputs section precedes the Artifacts section; no file-typed (artifact)
    # entry may appear before the Artifacts heading.
    local before="${output%%Artifacts*}"
    [[ "${before}" != *"[file"* ]]
}

@test "default: an artifact result carries the 'result' tag, a plain artifact does not" {
    run knit describe --format default --only tabulate --no-color
    [ "$status" -eq 0 ]
    [[ "${output}" == *"table"*"[file, result]"* ]]
    [[ "${output}" == *"dump"*"[file]"* ]]
}

@test "default: a command with no artifact has no Artifacts section" {
    run knit describe --format default --only greet --no-color
    [ "$status" -eq 0 ]
    [[ "${output}" != *"Artifacts"* ]]
}

# ---------- markdown ----------

@test "markdown: the Outputs table has a Result column filled for a result" {
    run knit describe --format markdown --only tabulate
    [ "$status" -eq 0 ]
    [[ "${output}" == *"| Name | Type | Default | Result | Description |"* ]]
    [[ "${output}" == *'| `pi` | real | `0` | result | Estimated value of pi. |'* ]]
}

@test "markdown: artifacts move to an Artifacts table with a Result column" {
    run knit describe --format markdown --only tabulate
    [ "$status" -eq 0 ]
    [[ "${output}" == *"#### Artifacts"* ]]
    [[ "${output}" == *"| Name | Type | Result | Description |"* ]]
    [[ "${output}" == *'| `table` | file | result | Computed dataset (CSV). |'* ]]
    [[ "${output}" == *'| `dump` | file |  | Environment capture. |'* ]]
}

@test "markdown: an artifact is not listed in the Outputs table" {
    run knit describe --format markdown --only tabulate
    [ "$status" -eq 0 ]
    local outputs_sec="${output#*#### Outputs}"
    outputs_sec="${outputs_sec%%#### Artifacts*}"
    [[ "${outputs_sec}" != *'`table`'* ]]
    [[ "${outputs_sec}" != *'`dump`'* ]]
}

@test "markdown: a command with no artifact has no Artifacts section" {
    run knit describe --format markdown --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" != *"#### Artifacts"* ]]
}
