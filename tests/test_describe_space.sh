#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
    _register_fixture
}

# A small command carrying declared search domains of each kind, plus a
# parameter with no domain and a flag.
_register_fixture() {
    knit_register "tune" knit_empty "A tunable command."
    knit_with_optional "lr:real" "0.01" "learning rate" --domain '[1e-5..1.0]' --log
    knit_with_optional "batch:integer" "32" "batch size" --domain '{16,32,64}'
    knit_with_optional "input:string" "" "input file" --domain '@glob:data/*.txt'
    knit_with_optional "plain:string" "x" "no domain"
    knit_with_flag "verbose" "be loud"
    knit_done
}

# ---------- default format ----------

@test "default --space annotates swept parameters" {
    run knit describe --only tune --space --no-color
    [ "$status" -eq 0 ]
    [[ "$output" == *"range [1e-5,1.0] log"* ]]
    [[ "$output" == *"values {16,32,64}"* ]]
    [[ "$output" == *"glob data/*.txt"* ]]
}

@test "default without --space shows no domain note" {
    run knit describe --only tune --no-color
    [ "$status" -eq 0 ]
    [[ "$output" != *"range ["* ]]
    [[ "$output" != *"values {"* ]]
}

@test "default --space leaves a no-domain parameter unannotated" {
    run knit describe --only tune --space --no-color
    [ "$status" -eq 0 ]
    [[ "$output" == *"--plain <value>  [default: 'x'] no domain"* ]]
}

# ---------- markdown format ----------

@test "markdown --space puts the domain in the constraints column" {
    run knit describe --only tune --space --format markdown
    [ "$status" -eq 0 ]
    [[ "$output" == *'space: `range [1e-5,1.0] log`'* ]]
    [[ "$output" == *'space: `values {16,32,64}`'* ]]
}

# ---------- json format ----------

@test "json --space embeds a structured space object" {
    knit_test_require_jq
    run knit describe --only tune --space --format json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.commands[0].parameters.optional[] | select(.name=="lr") | .space.kind' <<<"$output")" = "range" ]
    [ "$(jq -r '.commands[0].parameters.optional[] | select(.name=="lr") | .space.lo' <<<"$output")" = "1e-5" ]
    [ "$(jq -r '.commands[0].parameters.optional[] | select(.name=="lr") | .space.log' <<<"$output")" = "true" ]
    [ "$(jq -r '.commands[0].parameters.optional[] | select(.name=="batch") | .space.values | join(",")' <<<"$output")" = "16,32,64" ]
    [ "$(jq -r '.commands[0].parameters.optional[] | select(.name=="input") | .space.glob' <<<"$output")" = "data/*.txt" ]
}

@test "json --space omits space for a parameter with no domain" {
    knit_test_require_jq
    run knit describe --only tune --space --format json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.commands[0].parameters.optional[] | select(.name=="plain") | has("space")' <<<"$output")" = "false" ]
}

@test "json is well-formed with --space (pretty and compact)" {
    knit_test_require_jq
    run knit describe --only tune --space --format json
    [ "$status" -eq 0 ]
    jq -e . <<<"$output" >/dev/null
    run knit describe --only tune --space --format json --compact
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | wc -l)" -eq 0 ]
    jq -e . <<<"$output" >/dev/null
}

@test "json without --space has no space key" {
    knit_test_require_jq
    run knit describe --only tune --format json
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.commands[0].parameters.optional[] | has("space")] | any' <<<"$output")" = "false" ]
}

# ---------- yaml format ----------

@test "yaml --space emits a nested space mapping" {
    run knit describe --only tune --space --format yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"space:"* ]]
    [[ "$output" == *"kind: range"* ]]
    [[ "$output" == *"log: true"* ]]
    [[ "$output" == *'values: ["16", "32", "64"]'* ]]
}

# ---------- deferred validation surfaces on read ----------

@test "describe --space is fatal on an invalid declared domain" {
    knit_register "bad" knit_empty "A command with a bad domain."
    # A range on a string parameter: recorded verbatim, caught only on read.
    knit_with_optional "name:string" "x" "a name" --domain '[1..9]'
    knit_done
    run knit describe --only bad --space --no-color
    [ "$status" -ne 0 ]
}

@test "describe without --space tolerates an invalid declared domain" {
    knit_register "bad2" knit_empty "A command with a bad domain."
    knit_with_optional "name:string" "x" "a name" --domain '[1..9]'
    knit_done
    run knit describe --only bad2 --no-color
    [ "$status" -eq 0 ]
}
