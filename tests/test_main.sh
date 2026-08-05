#!/usr/bin/env bats

# The _KNIT_JUMP_TO_DIR jump block runs at *source* time (end of main.sh), so
# each test sources knit.sh in a fresh `bash -c` subshell with the environment
# arranged beforehand, then observes the resulting cwd. Sourcing by absolute
# path keeps these tests independent of the starting directory.

setup() {
    _KNIT_REPO="${BATS_TEST_DIRNAME}/.."
    _KNIT_TARGET="$(mktemp -d)"
    _KNIT_START="$(mktemp -d)"
}

teardown() {
    rm -rf "${_KNIT_TARGET}" "${_KNIT_START}"
}

@test "jump: cd to _KNIT_JUMP_TO_DIR then unset it" {
    run bash -c '
        cd "$3" || exit 99
        export _KNIT_JUMP_TO_DIR="$2"
        source "$1/knit.sh"
        printf "PWD=%s\n" "${PWD}"
        [[ -v _KNIT_JUMP_TO_DIR ]] && printf "VAR=set\n" || printf "VAR=unset\n"
    ' _ "${_KNIT_REPO}" "${_KNIT_TARGET}" "${_KNIT_START}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PWD=${_KNIT_TARGET}"* ]]
    [[ "$output" == *"VAR=unset"* ]]
}

@test "jump: no-op when _KNIT_JUMP_TO_DIR is unset" {
    run bash -c '
        cd "$2" || exit 99
        unset _KNIT_JUMP_TO_DIR
        source "$1/knit.sh"
        printf "PWD=%s\n" "${PWD}"
    ' _ "${_KNIT_REPO}" "${_KNIT_START}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PWD=${_KNIT_START}"* ]]
}

@test "jump: fatal when _KNIT_JUMP_TO_DIR points at a missing directory" {
    run bash -c '
        export _KNIT_JUMP_TO_DIR="$2"
        source "$1/knit.sh"
    ' _ "${_KNIT_REPO}" "${_KNIT_START}/does/not/exist"
    [ "$status" -ne 0 ]
}
