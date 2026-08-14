#!/usr/bin/env bats

# Tests for resource type registration and the download decorators
# (knit_register_resource, knit_with_git / knit_with_url / knit_with_local,
# knit_with_checksum) — declaration only, no downloading.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _knit_create_metadata_table
}

teardown() {
    knit_test_db_teardown
}

# Column names of a command's backing table, comma-joined.
_columns_of() {
    _knit_sqlite3 "PRAGMA table_info('$1');" | cut -d'|' -f2 | tr '\n' ','
}

# ---------- knit_register_resource ----------

@test "register creates a fetch:<type> command" {
    knit_register_resource "julia_code" "Julia source."
    knit_with_git "https://example.org/x.git" "main"
    knit_done
    _knit_set_find _KNIT_COMMANDS "$(_knit_command_mangle "fetch:julia_code")"
}

@test "register records the type in the resource registry" {
    knit_register_resource "julia_code" "Julia source."
    knit_with_git "https://example.org/x.git" "main"
    knit_done
    [ "${_KNIT_RESOURCES[julia_code]}" = "1" ]
}

@test "register marks the command as a resource" {
    knit_register_resource "julia_code" "Julia source."
    knit_with_git "https://example.org/x.git" "main"
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "fetch:julia_code")
    _knit_command_is_resource "${cmd}"
}

@test "register backs the type with a resource:<type> table" {
    knit_register_resource "julia_code" "Julia source."
    knit_with_git "https://example.org/x.git" "main"
    knit_done
    local cols
    cols=$(_columns_of "resource:julia_code")
    [[ "${cols}" == *id* ]]
}

@test "register rejects an invalid type name" {
    run knit_register_resource "bad/name" "Nope."
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a valid name"* ]]
}

@test "register with no download method is fatal at knit_done" {
    knit_register_resource "r" "No method."
    run knit_done
    [ "$status" -ne 0 ]
    [[ "$output" == *"no download method"* ]]
}

# ---------- knit_with_git ----------

@test "git decorator sets the method marker" {
    knit_register_resource "r" "d"
    knit_with_git "https://example.org/x.git" "main"
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "fetch:r")
    local marker="_KNIT_CMD_${cmd}_fetch_method"
    [ "${!marker}" = "git" ]
}

@test "git decorator declares url and ref parameters (table columns)" {
    knit_register_resource "r" "d"
    knit_with_git "https://example.org/x.git" "main"
    knit_done
    local cols
    cols=$(_columns_of "resource:r")
    [[ "${cols}" == *url* ]]
    [[ "${cols}" == *ref* ]]
}

@test "git decorator requires a url" {
    knit_register_resource "r" "d"
    run knit_with_git "" "main"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a repository URL"* ]]
}

@test "git decorator requires a ref" {
    knit_register_resource "r" "d"
    run knit_with_git "https://example.org/x.git"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a git ref"* ]]
}

# ---------- knit_with_url ----------

@test "url decorator sets the method marker" {
    knit_register_resource "r" "d"
    knit_with_url "https://example.org/x.tar.gz"
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "fetch:r")
    local marker="_KNIT_CMD_${cmd}_fetch_method"
    [ "${!marker}" = "url" ]
}

@test "url decorator declares url and uncompress (table columns)" {
    knit_register_resource "r" "d"
    knit_with_url "https://example.org/x.tar.gz"
    knit_done
    local cols
    cols=$(_columns_of "resource:r")
    [[ "${cols}" == *url* ]]
    [[ "${cols}" == *uncompress* ]]
}

@test "url decorator requires a url" {
    knit_register_resource "r" "d"
    run knit_with_url ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a URL"* ]]
}

# ---------- knit_with_local ----------

@test "local decorator sets the method marker" {
    knit_register_resource "r" "d"
    knit_with_local "/data/x"
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "fetch:r")
    local marker="_KNIT_CMD_${cmd}_fetch_method"
    [ "${!marker}" = "local" ]
}

@test "local decorator declares path and copy (table columns)" {
    knit_register_resource "r" "d"
    knit_with_local "/data/x"
    knit_done
    local cols
    cols=$(_columns_of "resource:r")
    [[ "${cols}" == *path* ]]
    [[ "${cols}" == *copy* ]]
}

@test "local decorator requires a path" {
    knit_register_resource "r" "d"
    run knit_with_local ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a source path"* ]]
}

# ---------- exactly-one / mutual exclusion ----------

@test "a second download decorator (same backend) is fatal" {
    knit_register_resource "r" "d"
    knit_with_git "https://example.org/x.git" "main"
    run knit_with_git "https://example.org/y.git" "dev"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at most one download method"* ]]
}

@test "a second download decorator (different backend) is fatal" {
    knit_register_resource "r" "d"
    knit_with_git "https://example.org/x.git" "main"
    run knit_with_url "https://example.org/y.tar.gz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at most one download method"* ]]
}

# ---------- decorators outside a resource registration ----------

@test "git decorator outside a resource registration is fatal" {
    run knit_with_git "https://example.org/x.git" "main"
    [ "$status" -ne 0 ]
    [[ "$output" == *"only for resources"* ]]
}

@test "checksum decorator outside a resource registration is fatal" {
    run knit_with_checksum "abc"
    [ "$status" -ne 0 ]
    [[ "$output" == *"only for resources"* ]]
}

# ---------- knit_with_checksum ----------

@test "checksum decorator records the pin marker" {
    knit_register_resource "r" "d"
    knit_with_git "https://example.org/x.git" "main"
    knit_with_checksum "deadbeef"
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "fetch:r")
    local marker="_KNIT_CMD_${cmd}_checksum"
    [ "${!marker}" = "deadbeef" ]
}

@test "checksum decorator requires a value" {
    knit_register_resource "r" "d"
    knit_with_git "https://example.org/x.git" "main"
    run knit_with_checksum ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a sha256"* ]]
}

@test "checksum decorator is fatal when declared twice" {
    knit_register_resource "r" "d"
    knit_with_git "https://example.org/x.git" "main"
    knit_with_checksum "aaa"
    run knit_with_checksum "bbb"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at most once"* ]]
}

@test "a resource without a checksum has no checksum marker" {
    knit_register_resource "r" "d"
    knit_with_git "https://example.org/x.git" "main"
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "fetch:r")
    local marker="_KNIT_CMD_${cmd}_checksum"
    [ -z "${!marker:-}" ]
}
