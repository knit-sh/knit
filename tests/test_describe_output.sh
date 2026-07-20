#!/usr/bin/env bats

setup() {
    source knit.sh
    _register_fixture
    _KNIT_OUT_DIR=$(mktemp -d)
}

teardown() {
    [[ -n "${_KNIT_OUT_DIR}" ]] && rm -rf "${_KNIT_OUT_DIR}"
}

# A small user command so the description has content to write.
_register_fixture() {
    knit_register knit_empty "greet" "Say hello to someone."
    knit_with_required "name:string" "Name of the person to greet."
    knit_done
}

@test "--output writes the description to a file and not to stdout" {
    local f="${_KNIT_OUT_DIR}/desc.json"
    run knit describe --format json --only greet --output "${f}"
    [ "$status" -eq 0 ]
    [ -z "${output}" ]
    [ -f "${f}" ]
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${f}"
}

@test "the file holds the same content --output-less would print to stdout" {
    local f="${_KNIT_OUT_DIR}/desc.json"
    knit describe --format json --only greet --output "${f}"
    run knit describe --format json --only greet
    [ "$status" -eq 0 ]
    [ "${output}" = "$(cat "${f}")" ]
}

@test "--output honors the chosen format" {
    local f="${_KNIT_OUT_DIR}/desc.yaml"
    run knit describe --format yaml --only greet --output "${f}"
    [ "$status" -eq 0 ]
    grep -q '^commands:' "${f}"
}

@test "writing the default format to a file emits no ANSI color codes" {
    local f="${_KNIT_OUT_DIR}/desc.txt"
    run knit describe --format default --only greet --output "${f}"
    [ "$status" -eq 0 ]
    ! grep -q $'\x1b' "${f}"
}

@test "--output overwrites an existing file" {
    local f="${_KNIT_OUT_DIR}/desc.json"
    printf 'stale contents\n' > "${f}"
    run knit describe --format json --only greet --output "${f}"
    [ "$status" -eq 0 ]
    ! grep -q 'stale contents' "${f}"
}

@test "an unwritable --output path is a fatal error" {
    run knit describe --format json --only greet \
        --output "${_KNIT_OUT_DIR}/nonexistent-dir/desc.json"
    [ "$status" -ne 0 ]
}
