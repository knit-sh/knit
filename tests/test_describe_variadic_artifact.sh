#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
    _register_fixture
}

# A producer that declares a scalar artifact, a "*" collection (zero or more),
# and a "+" collection (one or more); and a consumer that declares a scalar
# input, a "*" input, and a "+" input. Together they exercise the cardinality
# marker on every describe format and on --help, for both directions.
_register_fixture() {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register_artifact "pngfile:file" "A PNG image."

    knit_register "make" knit_empty "Make outputs."
    knit_with_output_artifact "summary:csvfile" "The summary table."
    knit_with_output_artifact "frames:pngfile*" "Rendered frames."
    knit_with_output_artifact "report:csvfile+" "Report shards."
    knit_done

    knit_register "plot" _plot "Plot tables."
    knit_with_input_artifact "one:csvfile" "One table."
    knit_with_input_artifact "many:csvfile*" "Zero or more tables."
    knit_with_input_artifact "some:csvfile+" "One or more tables."
    _plot() { :; }
    knit_done
}

# Extract a value from the JSON in ${output} via a python expression on `d`.
_json() {
    printf '%s' "${output}" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

# Extract a value from the YAML in ${output} via a python expression on `d`.
_yaml() {
    printf '%s' "${output}" | python3 -c "import yaml,sys; d=yaml.safe_load(sys.stdin); print($1)"
}

# The producer/consumer command objects, as python expressions.
_MAKE="[c for c in d['commands'] if c['name']=='make'][0]"
_PLOT="[c for c in d['commands'] if c['name']=='plot'][0]"

# One artifact object of make by name, as a python expression.
_art() {
    printf "[a for a in ${_MAKE}['artifacts'] if a['name']=='%s'][0]" "$1"
}

# One parameter object of plot by name (any group), as a python expression.
_param() {
    printf "[p for g in ('required','optional','flags') for p in ${_PLOT}['parameters'][g] if p['name']=='%s'][0]" "$1"
}

# ---------- JSON: output side ----------

@test "json: a variadic output carries a cardinality field, a scalar output does not" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "$(_art frames)['cardinality']")" = "zero or more" ]
    [ "$(_json "$(_art report)['cardinality']")" = "one or more" ]
    [ "$(_json "'cardinality' in $(_art summary)")" = "False" ]
}

# ---------- JSON: input side ----------

@test "json: a variadic input parameter carries a cardinality field, a scalar one does not" {
    run _knit_describe_json
    [ "$status" -eq 0 ]
    [ "$(_json "$(_param many)['cardinality']")" = "zero or more" ]
    [ "$(_json "$(_param some)['cardinality']")" = "one or more" ]
    [ "$(_json "'cardinality' in $(_param one)")" = "False" ]
}

# ---------- YAML ----------

@test "yaml: variadic outputs and inputs carry a cardinality field, scalars do not" {
    run _knit_describe_yaml
    [ "$status" -eq 0 ]
    local frames="[a for a in ${_MAKE}['artifacts'] if a['name']=='frames'][0]"
    local report="[a for a in ${_MAKE}['artifacts'] if a['name']=='report'][0]"
    local summary="[a for a in ${_MAKE}['artifacts'] if a['name']=='summary'][0]"
    [ "$(_yaml "${frames}['cardinality']")" = "zero or more" ]
    [ "$(_yaml "${report}['cardinality']")" = "one or more" ]
    [ "$(_yaml "'cardinality' in ${summary}")" = "False" ]
    local many="[p for g in ('required','optional','flags') for p in ${_PLOT}['parameters'][g] if p['name']=='many'][0]"
    local one="[p for g in ('required','optional','flags') for p in ${_PLOT}['parameters'][g] if p['name']=='one'][0]"
    [ "$(_yaml "${many}['cardinality']")" = "zero or more" ]
    [ "$(_yaml "'cardinality' in ${one}")" = "False" ]
}

# ---------- default (human) ----------

@test "default: a variadic output marks its cardinality, a scalar output does not" {
    run knit describe --format default --only make --no-color
    [ "$status" -eq 0 ]
    [[ "${output}" == *"frames"*"[pngfile, zero or more]"* ]]
    [[ "${output}" == *"report"*"[csvfile, one or more]"* ]]
    local line
    line=$(printf '%s\n' "${output}" | grep -E '^ +summary ')
    [[ "${line}" == *"[csvfile]"* ]]
    [[ "${line}" != *"more"* ]]
}

@test "default: a variadic input marks its cardinality, a scalar input does not" {
    run knit describe --format default --only plot --no-color
    [ "$status" -eq 0 ]
    local m s o
    m=$(printf '%s\n' "${output}" | grep -E '^ +--many ')
    s=$(printf '%s\n' "${output}" | grep -E '^ +--some ')
    o=$(printf '%s\n' "${output}" | grep -E '^ +--one ')
    [[ "${m}" == *"artifact: csvfile, zero or more"* ]]
    [[ "${s}" == *"artifact: csvfile, one or more"* ]]
    [[ "${o}" == *"artifact: csvfile"* ]]
    [[ "${o}" != *"more"* ]]
}

# ---------- markdown ----------

@test "markdown: a variadic output folds its cardinality into the Type cell" {
    run knit describe --format markdown --only make
    [ "$status" -eq 0 ]
    [[ "${output}" == *'| `frames` | pngfile, zero or more |'* ]]
    [[ "${output}" == *'| `report` | csvfile, one or more |'* ]]
    [[ "${output}" == *'| `summary` | csvfile |  |'* ]]
}

@test "markdown: a variadic input marks its cardinality in the constraints column" {
    run knit describe --format markdown --only plot
    [ "$status" -eq 0 ]
    [[ "${output}" == *'artifact: `csvfile`; zero or more'* ]]
    [[ "${output}" == *'artifact: `csvfile`; one or more'* ]]
}

# ---------- --help ----------

@test "--help marks a variadic input's cardinality, a scalar input unchanged" {
    run _knit_invoke_command "plot" --help
    [ "$status" -eq 0 ]
    [[ "${output}" == *"[required, artifact: csvfile, one or more]"* ]]
    [[ "${output}" == *"artifact: csvfile, zero or more"* ]]
    local o
    o=$(printf '%s\n' "${output}" | grep -E -- '--one ')
    [[ "${o}" == *"[required, artifact: csvfile]"* ]]
    [[ "${o}" != *"more"* ]]
}
