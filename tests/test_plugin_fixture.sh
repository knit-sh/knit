#!/usr/bin/env bats

# End-to-end coverage of the expressive plugin API, offline. It sources a local
# fixture plugin (tests/fixtures/plugin/plugin.sh) the way Knit sources a real
# plugin and checks each part: a command, a decorator authored from the public
# registration surface and exposed as a shorthand, a write under the ".knit"
# directory, and an extension of a core command.

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_require_sqlite
    knit_test_db_setup

    __TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${__TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"

    # The extend test invokes "metadata store", which needs the metadata table.
    _knit_create_metadata_table

    # shellcheck disable=SC1091 # fixture path is resolved at test runtime
    source "${BATS_TEST_DIRNAME}/fixtures/plugin/plugin.sh"
}

teardown() {
    rm -rf "${__TEST_TMPDIR}"
    knit_test_db_teardown
}

@test "the fixture registers its command and runs the decorated body" {
    run knit fixture hello --who Ada
    [ "$status" -eq 0 ]
    # The decorator's "run before" callback prints the tag ahead of the body.
    [[ "$output" == *"TAG:fixture"* ]]
    [[ "$output" == *"hi Ada"* ]]
}

@test "the command writes under the .knit directory via knit_prefix" {
    knit fixture hello --who Ada
    knit fixture hello --who Bob
    [ -f "${_KNIT_PREFIX}/fixture/log" ]
    run cat "${_KNIT_PREFIX}/fixture/log"
    [[ "$output" == *"Ada"* ]]
    [[ "$output" == *"Bob"* ]]
}

@test "the decorator adds a help note to the command" {
    run knit fixture hello --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Requirements"* ]]
    [[ "$output" == *'Prints the tag "fixture" before it runs.'* ]]
}

@test "the decorator shorthand is registered for the user" {
    # knit_register_shorthand defined @with_tag for the user's own experiment.
    declare -F @with_tag
}

@test "the shorthand decorator rejects a second use on one command" {
    knit_register "fixturedup" knit_empty "throwaway"
    fixture_with_tag one
    run fixture_with_tag two
    [ "$status" -ne 0 ]
    [[ "$output" == *"more than once"* ]]
}

@test "the fixture extends the core metadata store command with a new option" {
    run knit metadata store --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--fixture-note"* ]]

    # The extended option is accepted on a real invocation.
    run knit metadata store --key k --value v --fixture-note hi
    [ "$status" -eq 0 ]
}
