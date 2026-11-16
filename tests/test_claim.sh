#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- claim group command registration ----------

@test "claim group command is registered" {
    _knit_set_find _KNIT_COMMANDS "claim"
}

@test "claim group command is a builtin" {
    [ "${_KNIT_CMD_claim_is_builtin}" = "true" ]
}

@test "claim group command records no provenance" {
    [ "${_KNIT_CMD_claim_provenance}" = "without" ]
}

# ---------- knit_register_claim ----------

@test "knit_register_claim adds the normalized name to _KNIT_CLAIMS" {
    _test_claim_fn() { :; }
    knit_register_claim "a-beats-b" "_test_claim_fn" "A beats B by @p on @d."
    knit_done
    [[ -v _KNIT_CLAIMS["a_beats_b"] ]]
}

@test "knit_register_claim registers the claim:<name> command" {
    _test_claim_fn() { :; }
    knit_register_claim "a-beats-b" "_test_claim_fn" "A beats B by @p on @d."
    knit_done
    _knit_set_find _KNIT_COMMANDS "claim__1__a_beats_b"
}

@test "knit_register_claim marks the command type claim" {
    _test_claim_fn() { :; }
    knit_register_claim "a-beats-b" "_test_claim_fn" "A beats B by @p on @d."
    knit_done
    local cmd
    _knit_command_mangle cmd "claim:a-beats-b"
    local var="_KNIT_CMD_${cmd}_type"
    [ "${!var}" = "claim" ]
}

@test "knit_register_claim applies knit_without_provenance" {
    _test_claim_fn() { :; }
    knit_register_claim "a-beats-b" "_test_claim_fn" "A beats B by @p on @d."
    knit_done
    local cmd
    _knit_command_mangle cmd "claim:a-beats-b"
    local var="_KNIT_CMD_${cmd}_provenance"
    [ "${!var}" = "without" ]
}

@test "knit_register_claim stores the raw statement template" {
    _test_claim_fn() { :; }
    knit_register_claim "a-beats-b" "_test_claim_fn" "A beats B by @p on @d."
    knit_done
    local cmd
    _knit_command_mangle cmd "claim:a-beats-b"
    local var="_KNIT_CLAIM_${cmd}_statement"
    [ "${!var}" = "A beats B by @p on @d." ]
}

@test "knit_register_claim declares a table named after the claim" {
    _test_claim_fn() { :; }
    knit_register_claim "a-beats-b" "_test_claim_fn" "A beats B by @p on @d."
    knit_done
    local cmd
    _knit_command_mangle cmd "claim:a-beats-b"
    local var="_KNIT_CMD_${cmd}_table"
    [ "${!var}" = "a_beats_b" ]
}

@test "the claim table is created in the database" {
    _test_claim_fn() { :; }
    knit_register_claim "a-beats-b" "_test_claim_fn" "A beats B by @p on @d."
    knit_done
    local result
    result=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='a_beats_b';")
    [ "$result" -eq 1 ]
}

@test "a claim registered with underscores normalizes to the same name" {
    _test_claim_fn() { :; }
    knit_register_claim "a_beats_b" "_test_claim_fn" "A beats B."
    knit_done
    [[ -v _KNIT_CLAIMS["a_beats_b"] ]]
    _knit_set_find _KNIT_COMMANDS "claim__1__a_beats_b"
}

# ---------- reserved names ----------

@test "knit_register_claim rejects the reserved name check" {
    _reserved_fn() { :; }
    run knit_register_claim "check" _reserved_fn "A statement."
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved"* ]]
}

@test "knit_register_claim rejects the reserved name list" {
    _reserved_fn() { :; }
    run knit_register_claim "list" _reserved_fn "A statement."
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved"* ]]
}
