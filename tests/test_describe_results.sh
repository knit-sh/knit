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
    knit_with_artifact "table:file" "Computed dataset (CSV)." --result
    knit_with_artifact "dump:file" "Environment capture."
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

# Extract a value from the YAML in ${output} via a python expression on `d`.
_yaml() {
    printf '%s' "${output}" | python3 -c "import yaml,sys; d=yaml.safe_load(sys.stdin); print($1)"
}

# ---------- JSON ----------

@test "json: a value output with --result reports result true, artifact false" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "$(_out pi)['result']")" = "True" ]
    [ "$(_json "$(_out pi)['artifact']")" = "False" ]
}

@test "json: a plain output reports result false, artifact false" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "$(_out scratch)['result']")" = "False" ]
    [ "$(_json "$(_out scratch)['artifact']")" = "False" ]
}

@test "json: an artifact with --result reports result true, artifact true" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "$(_out table)['result']")" = "True" ]
    [ "$(_json "$(_out table)['artifact']")" = "True" ]
}

@test "json: an artifact without --result reports result false, artifact true" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "$(_out dump)['result']")" = "False" ]
    [ "$(_json "$(_out dump)['artifact']")" = "True" ]
}

@test "json: an artifact stays in the outputs array" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "'table' in [o['name'] for o in ${_TAB}['outputs']]")" = "True" ]
    [ "$(_json "'dump' in [o['name'] for o in ${_TAB}['outputs']]")" = "True" ]
}

@test "json: compact form carries the same result/artifact booleans" {
    run _knit_describe_json_compact
    [ "$status" -eq 0 ]
    [ "$(_json "$(_out table)['result']")" = "True" ]
    [ "$(_json "$(_out table)['artifact']")" = "True" ]
}

# ---------- YAML ----------

@test "yaml: result and artifact booleans mirror the JSON model" {
    run _knit_describe_yaml
    [ "$status" -eq 0 ]
    local tab="[c for c in d['commands'] if c['name']=='tabulate'][0]"
    local pi="[o for o in ${tab}['outputs'] if o['name']=='pi'][0]"
    local table="[o for o in ${tab}['outputs'] if o['name']=='table'][0]"
    local dump="[o for o in ${tab}['outputs'] if o['name']=='dump'][0]"
    [ "$(_yaml "${pi}['result']")" = "True" ]
    [ "$(_yaml "${pi}['artifact']")" = "False" ]
    [ "$(_yaml "${table}['result']")" = "True" ]
    [ "$(_yaml "${table}['artifact']")" = "True" ]
    [ "$(_yaml "${dump}['result']")" = "False" ]
    [ "$(_yaml "${dump}['artifact']")" = "True" ]
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
    # entry may appear before the Artifacts heading. (The "table-checksum" /
    # "dump-checksum" companion columns are string outputs, so they legitimately
    # stay in Outputs; keying on the "[file" bracket avoids matching them.)
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
