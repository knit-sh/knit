#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
    _register_fixture
}

# Register a user command whose function body contains characters that must be
# escaped by the JSON and YAML serializers (double quotes, a backslash, a pipe,
# and a newline), plus a second command sharing the same function, so the
# implementation capture is exercised across formats.
_register_fixture() {
    my_impl() {
        echo "he said \"hi\""
        printf '%s\n' 'a|b'
    }
    knit_register my_impl "greet" "Say hello to someone."
    knit_with_required "name:string" "Name of the person to greet."
    knit_done
}

# Extract a value from the JSON in ${output} via a python expression on `d`.
_json() {
    printf '%s' "${output}" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

# Fail (do not skip) a test that needs a YAML parser when yq is not installed:
# CI is expected to provide yq, so a missing parser is an error, not a skip.
_require_yq() {
    if ! command -v yq >/dev/null 2>&1; then
        printf 'yq is required for the describe implementation tests but is not installed\n' >&2
        return 1
    fi
}

# ---------- presence / absence ----------

@test "the flag adds the implementation to a user command (json)" {
    run knit describe --format json --only greet --include-implementation
    [ "$status" -eq 0 ]
    [ "$(_json "'implementation' in [c for c in d['commands'] if c['name']=='greet'][0]")" = "True" ]
}

@test "without the flag no implementation is emitted (json)" {
    run knit describe --format json --only greet
    [ "$status" -eq 0 ]
    [ "$(_json "'implementation' in [c for c in d['commands'] if c['name']=='greet'][0]")" = "False" ]
}

@test "a builtin command never carries an implementation (json)" {
    run knit describe --format json --only submit --include-implementation
    [ "$status" -eq 0 ]
    [ "$(_json "'implementation' in [c for c in d['commands'] if c['name']=='submit'][0]")" = "False" ]
}

@test "the captured body is the declare -f output" {
    run knit describe --format json --only greet --include-implementation
    [ "$status" -eq 0 ]
    [ "$(_json "[c for c in d['commands'] if c['name']=='greet'][0]['implementation'].startswith('my_impl ()')")" = "True" ]
    [ "$(_json "'he said' in [c for c in d['commands'] if c['name']=='greet'][0]['implementation']")" = "True" ]
}

# ---------- json/yaml escaping of a tricky body ----------

@test "a body with quotes, backslashes and newlines round-trips through JSON" {
    run knit describe --format json --only greet --include-implementation
    [ "$status" -eq 0 ]
    # The whole document parses, proving the embedded body is escaped correctly.
    printf '%s' "${output}" | python3 -c 'import json,sys; json.load(sys.stdin)'
    # The embedded double quotes survived (chr(34) avoids nested shell quoting).
    [ "$(_json "chr(34) in [c for c in d['commands'] if c['name']=='greet'][0]['implementation']")" = "True" ]
}

@test "the yaml implementation is a literal block scalar" {
    run knit describe --format yaml --only greet --include-implementation
    [ "$status" -eq 0 ]
    [[ "${output}" == *'implementation: |-'* ]]
    [[ "${output}" == *'my_impl ()'* ]]
}

@test "yaml carries the same implementation content as json" {
    _require_yq
    # yq reads YAML by default and JSON is valid YAML, so pass both through it.
    local from_json from_yaml
    from_json=$(knit describe --format json --only greet --include-implementation \
        | yq -c '.commands[0].implementation')
    from_yaml=$(knit describe --format yaml --only greet --include-implementation \
        | yq -c '.commands[0].implementation')
    [ "${from_json}" = "${from_yaml}" ]
}

# ---------- default format ----------

@test "the default format prints an Implementation section for a user command" {
    run knit describe --format default --only greet --include-implementation --no-color
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'Implementation\n'* ]]
    [[ "${output}" == *'my_impl ()'* ]]
}

@test "the default format omits Implementation without the flag" {
    run knit describe --format default --only greet --no-color
    [ "$status" -eq 0 ]
    [[ "${output}" != *'Implementation'* ]]
}

@test "the default format never dumps a builtin body" {
    run knit describe --format default --only submit --include-implementation --no-color
    [ "$status" -eq 0 ]
    [[ "${output}" != *'Implementation'* ]]
}

# ---------- markdown format ----------

@test "markdown renders a fenced bash Implementation block" {
    run knit describe --format markdown --only greet --include-implementation
    [ "$status" -eq 0 ]
    [[ "${output}" == *$'#### Implementation\n'* ]]
    [[ "${output}" == *$'```bash\n'* ]]
    [[ "${output}" == *'my_impl ()'* ]]
}

@test "markdown omits the Implementation block without the flag" {
    run knit describe --format markdown --only greet
    [ "$status" -eq 0 ]
    [[ "${output}" != *'#### Implementation'* ]]
}

@test "markdown never dumps a builtin body" {
    run knit describe --format markdown --only submit --include-implementation
    [ "$status" -eq 0 ]
    [[ "${output}" != *'#### Implementation'* ]]
}
