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

# ---------- statement rendering (_knit_claim_render) ----------
#
# A claim with a condition parameter "d" and an output "s" is registered, and its
# output store is seeded, so the renderer resolves both kinds of token.

_register_render_claim() {
    _render_fn() { :; }
    knit_register_claim "a-beats-b" "_render_fn" "unused template"
    knit_with_required "d:string"  "Dataset name."
    knit_with_output   "s:real" "0" "Speedup factor."
    knit_done
    _knit_command_mangle _CLAIM_CMD "claim:a-beats-b"
}

@test "render: a bare token is interpolated with its output value" {
    _register_render_claim
    local -n store="_KNIT_CMD_${_CLAIM_CMD}_output_value"
    store["s"]="1.8"
    local out
    _knit_claim_render out "@s faster" "${_CLAIM_CMD}"
    [ "${out}" = "1.8 faster" ]
}

@test "render: punctuation ends a token, so a statement can end in one" {
    _register_render_claim
    local -n store="_KNIT_CMD_${_CLAIM_CMD}_output_value"
    store["s"]="1.8"
    local out
    _knit_claim_render out "@s." "${_CLAIM_CMD}"
    [ "${out}" = "1.8." ]
    _knit_claim_render out "by @s%" "${_CLAIM_CMD}"
    [ "${out}" = "by 1.8%" ]
}

@test "render: an undeclared bare token is a fatal error" {
    _register_render_claim
    run _knit_claim_render out "@sx faster" "${_CLAIM_CMD}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"@sx"* ]]
    [[ "$output" == *"not a declared parameter or output"* ]]
}

@test "render: the brace form lets a value abut an identifier character" {
    _register_render_claim
    local -n store="_KNIT_CMD_${_CLAIM_CMD}_output_value"
    store["s"]="1.8"
    local out
    _knit_claim_render out "@{s}x faster" "${_CLAIM_CMD}"
    [ "${out}" = "1.8x faster" ]
}

@test "render: @@ renders a single literal @" {
    _register_render_claim
    local out
    _knit_claim_render out "cost @@ scale" "${_CLAIM_CMD}"
    [ "${out}" = "cost @ scale" ]
}

@test "render: an output with no recorded value falls back to its default" {
    _register_render_claim
    local out
    _knit_claim_render out "speedup @s" "${_CLAIM_CMD}"
    [ "${out}" = "speedup 0" ]
}

@test "render: a statement mixes a condition parameter and an output" {
    _register_render_claim
    local -n store="_KNIT_CMD_${_CLAIM_CMD}_output_value"
    store["s"]="18"
    local out
    _knit_claim_render out "A beats B by @s percent on @d." "${_CLAIM_CMD}" \
        --d cifar10
    [ "${out}" = "A beats B by 18 percent on cifar10." ]
}

@test "render: a condition parameter absent from the arguments renders empty" {
    _register_render_claim
    local out
    _knit_claim_render out "on @d" "${_CLAIM_CMD}"
    [ "${out}" = "on " ]
}

@test "render: an empty token name is a fatal error" {
    _register_render_claim
    run _knit_claim_render out "ends at @" "${_CLAIM_CMD}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]
}

@test "render: an unterminated brace token is a fatal error" {
    _register_render_claim
    run _knit_claim_render out "starts @{s here" "${_CLAIM_CMD}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unterminated"* ]]
}

@test "render: the brace form accepts a hyphenated name" {
    _gpn_fn() { :; }
    knit_register_claim "gpn" "_gpn_fn" "unused"
    knit_with_output "gpus-per-node:integer" "0" "GPUs per node."
    knit_done
    local cmd
    _knit_command_mangle cmd "claim:gpn"
    local -n store="_KNIT_CMD_${cmd}_output_value"
    store["gpus_per_node"]="4"
    local out
    _knit_claim_render out "@{gpus-per-node} GPUs" "${cmd}"
    [ "${out}" = "4 GPUs" ]
}

# ---------- verdict constants ----------

@test "verdict constants have the documented values" {
    [ "${KNIT_CLAIM_HOLDS}" -eq 0 ]
    [ "${KNIT_CLAIM_REFUTED}" -eq 1 ]
    [ "${KNIT_CLAIM_INSUFFICIENT}" -eq 2 ]
}

@test "a checker returning KNIT_CLAIM_REFUTED yields the refuted verdict" {
    _ref_fn() { return "${KNIT_CLAIM_REFUTED}"; }
    knit_register_claim "c-ref" "_ref_fn" "A beats B on @d"
    knit_with_required "d:string" "Dataset."
    knit_done
    run knit claim check -- c-ref --d x
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "✗ A beats B on x" ]
}

@test "a checker returning KNIT_CLAIM_INSUFFICIENT yields the insufficient verdict" {
    _ins_fn() { return "${KNIT_CLAIM_INSUFFICIENT}"; }
    knit_register_claim "c-ins" "_ins_fn" "A beats B on @d"
    knit_with_required "d:string" "Dataset."
    knit_done
    run knit claim check -- c-ins --d x
    [ "$status" -eq 2 ]
    [ "${lines[0]}" = "? A beats B on x — insufficient data" ]
}

# ---------- verdict mapping (_knit_claim_verdict_from_code) ----------

@test "verdict: exit code 0 maps to holds" {
    local v
    _knit_claim_verdict_from_code v 0
    [ "${v}" = "holds" ]
}

@test "verdict: exit code 1 maps to refuted" {
    local v
    _knit_claim_verdict_from_code v 1
    [ "${v}" = "refuted" ]
}

@test "verdict: exit code 2 maps to insufficient" {
    local v
    _knit_claim_verdict_from_code v 2
    [ "${v}" = "insufficient" ]
}

@test "verdict: any other exit code is not a verdict (empty)" {
    local v
    _knit_claim_verdict_from_code v 3
    [ -z "${v}" ]
}

# ---------- claim check (read-only) ----------
#
# Three claims whose checkers deterministically hold, refute, and report
# insufficient data, plus one whose checker errors. Each sets its output and
# returns the verdict code.

_register_check_claims() {
    _hold_fn()  { knit_output s 18;  return 0; }
    knit_register_claim "a-holds" "_hold_fn" "A beats B by @s percent on @d."
    knit_with_required "d:string"  "Dataset."
    knit_with_output   "s:integer" "0" "Margin."
    knit_done

    _refute_fn() { knit_output s -3; return 1; }
    knit_register_claim "a-refutes" "_refute_fn" "A beats B by @s percent on @d."
    knit_with_required "d:string"  "Dataset."
    knit_with_output   "s:integer" "0" "Margin."
    knit_done

    _insuff_fn() { return 2; }
    knit_register_claim "a-insuff" "_insuff_fn" "A beats B on @d"
    knit_with_required "d:string" "Dataset."
    knit_done

    _error_fn() { return 3; }
    knit_register_claim "a-errors" "_error_fn" "A beats B on @d"
    knit_with_required "d:string" "Dataset."
    knit_done
}

@test "claim check: a holding claim prints a green tick and exits 0" {
    _register_check_claims
    run knit claim check -- a-holds --d cifar10
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "✓ A beats B by 18 percent on cifar10." ]
}

@test "claim check: a refuted claim prints a cross and exits 1" {
    _register_check_claims
    run knit claim check -- a-refutes --d mnist
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "✗ A beats B by -3 percent on mnist." ]
}

@test "claim check: an insufficient claim notes it and exits 2" {
    _register_check_claims
    run knit claim check -- a-insuff --d tiny
    [ "$status" -eq 2 ]
    [ "${lines[0]}" = "? A beats B on tiny — insufficient data" ]
}

@test "claim check: a checker error is reported distinctly and propagates its code" {
    _register_check_claims
    run knit claim check -- a-errors --d tiny
    [ "$status" -eq 3 ]
    [[ "$output" == *"checker error"* ]]
    [[ "$output" != *"✓"* ]]
    [[ "$output" != *"✗"* ]]
}

@test "claim check: a plain check records no row" {
    _register_check_claims
    run knit claim check -- a-holds --d cifar10
    [ "$status" -eq 0 ]
    local count
    count=$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM a_holds;")
    [ "${count}" -eq 0 ]
}

@test "claim check: an unknown claim is fatal" {
    _register_check_claims
    run knit claim check -- no-such-claim --d x
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown claim"* ]]
}

@test "claim check: a missing claim name is fatal" {
    _register_check_claims
    run knit claim check
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a claim name"* ]]
}

@test "claim check: --help renders usage without evaluating" {
    _register_check_claims
    run knit claim check --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"check"* ]]
    [[ "$output" == *"claim"* ]]
}

@test "claim check: the marker is colored when stdout is a terminal" {
    _register_check_claims
    # Force the terminal path (NO_COLOR unset, stdout a TTY) so the color branch
    # is exercised deterministically.
    _knit_stdout_is_terminal() { return 0; }
    unset NO_COLOR
    run knit claim check -- a-holds --d cifar10
    [ "$status" -eq 0 ]
    # The green SGR code precedes the tick; a reset follows it.
    [[ "$output" == *$'\033[32m'"✓"$'\033[0m'* ]]
}

@test "claim check: NO_COLOR suppresses the marker color" {
    _register_check_claims
    _knit_stdout_is_terminal() { return 0; }
    NO_COLOR=1 run knit claim check -- a-refutes --d mnist
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "✗ A beats B by -3 percent on mnist." ]
}
