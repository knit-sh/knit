#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
    _register_fixture
}

# A user command with a subcommand, an output and a parameter, so filtering can
# be exercised against both user and builtin commands. Invoked through the real
# "knit describe" entry point so the CLI framework expands the flags.
_register_fixture() {
    knit_register knit_empty "greet" "Say hello to someone."
    knit_with_optional "count:integer" "1" "Number of times to greet."
    knit_with_output "greeting:string" "" "The produced greeting."
    knit_done

    knit_register knit_empty "greet:formal" "Greet formally."
    knit_done
}

# Extract a value from the JSON in ${output} via a python expression on `d`.
_json() {
    printf '%s' "${output}" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

@test "without --only every non-hidden command is described" {
    run knit describe --format json
    [ "$status" -eq 0 ]
    [ "$(_json "'greet' in [c['name'] for c in d['commands']]")" = "True" ]
    [ "$(_json "'submit' in [c['name'] for c in d['commands']]")" = "True" ]
}

@test "hidden commands are excluded by default" {
    run knit describe --format json
    [ "$status" -eq 0 ]
    [ "$(_json "[c['name'] for c in d['commands'] if c['name'] in ('_run','__main__')]")" = "[]" ]
}

@test "--include-hidden reveals framework-private commands" {
    run knit describe --format json --include-hidden
    [ "$status" -eq 0 ]
    [ "$(_json "'__main__' in [c['name'] for c in d['commands']]")" = "True" ]
}

@test "--exclude-builtins drops framework commands" {
    run knit describe --format json --exclude-builtins
    [ "$status" -eq 0 ]
    [ "$(_json "[c['name'] for c in d['commands']]")" = "['greet']" ]
}

@test "--no-input-params omits the parameters object" {
    run knit describe --format json --no-input-params
    [ "$status" -eq 0 ]
    [ "$(_json "'parameters' in [c for c in d['commands'] if c['name']=='greet'][0]")" = "False" ]
    [ "$(_json "'outputs' in [c for c in d['commands'] if c['name']=='greet'][0]")" = "True" ]
}

@test "--no-output-params omits the outputs array" {
    run knit describe --format json --no-output-params
    [ "$status" -eq 0 ]
    [ "$(_json "'outputs' in [c for c in d['commands'] if c['name']=='greet'][0]")" = "False" ]
    [ "$(_json "'parameters' in [c for c in d['commands'] if c['name']=='greet'][0]")" = "True" ]
}

@test "both omit flags can be combined" {
    run knit describe --format json --no-input-params --no-output-params
    [ "$status" -eq 0 ]
    [ "$(_json "'parameters' in [c for c in d['commands'] if c['name']=='greet'][0]")" = "False" ]
    [ "$(_json "'outputs' in [c for c in d['commands'] if c['name']=='greet'][0]")" = "False" ]
}

@test "--only restricts the tree to the named commands" {
    run knit describe --format json --only greet
    [ "$status" -eq 0 ]
    [ "$(_json "[c['name'] for c in d['commands']]")" = "['greet']" ]
}

@test "--only without --recursive shows no subcommands" {
    run knit describe --format json --only greet
    [ "$status" -eq 0 ]
    [ "$(_json "[c for c in d['commands'] if c['name']=='greet'][0]['subcommands']")" = "[]" ]
}

@test "--only with --recursive includes the selected subtree" {
    run knit describe --format json --only greet --recursive
    [ "$status" -eq 0 ]
    [ "$(_json "[s['name'] for s in [c for c in d['commands'] if c['name']=='greet'][0]['subcommands']]")" = "['formal']" ]
}

@test "--only accepts several comma-separated commands" {
    run knit describe --format json --only "greet,submit"
    [ "$status" -eq 0 ]
    [ "$(_json "sorted(c['name'] for c in d['commands'])")" = "['greet', 'submit']" ]
}

@test "--only selects a subcommand and keeps its parent as a container" {
    run knit describe --format json --only "metadata:store"
    [ "$status" -eq 0 ]
    [ "$(_json "[c['name'] for c in d['commands']]")" = "['metadata']" ]
    [ "$(_json "[s['name'] for s in [c for c in d['commands'] if c['name']=='metadata'][0]['subcommands']]")" = "['store']" ]
}
