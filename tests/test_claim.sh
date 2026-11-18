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
    knit_with_output   "s:real" "Speedup factor." --unset "0"
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

# A claim whose statement references an output that the checker never sets AND
# that declares no --unset fallback: the token must render as the visible
# "<unset>" marker (never a fabricated value), and claim check must warn.

_register_unmeasured_claim() {
    _unmeasured_fn() { :; }
    knit_register_claim "needs-measure" "_unmeasured_fn" "unused template"
    knit_with_output "m:real" "A measured margin, percent."
    knit_done
    _knit_command_mangle _UNMEASURED_CMD "claim:needs-measure"
}

@test "render: a fallback-less unset output renders the <unset> marker" {
    _register_unmeasured_claim
    local out
    _knit_claim_render out "margin @m percent" "${_UNMEASURED_CMD}"
    [ "${out}" = "margin <unset> percent" ]
}

@test "render: a fallback-less unset output warns when rendered" {
    _register_unmeasured_claim
    # _knit_claim_render returns via nameref, so it prints nothing on stdout; the
    # only output `run` captures is the warning on stderr.
    run _knit_claim_render out "margin @m percent" "${_UNMEASURED_CMD}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"was never set by the checker"* ]]
    [[ "$output" == *"<unset>"* ]]
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
    knit_with_output "gpus-per-node:integer" "GPUs per node." --unset "0"
    knit_done
    local cmd
    _knit_command_mangle cmd "claim:gpn"
    local -n store="_KNIT_CMD_${cmd}_output_value"
    store["gpus_per_node"]="4"
    local out
    _knit_claim_render out "@{gpus-per-node} GPUs" "${cmd}"
    [ "${out}" = "4 GPUs" ]
}

@test "render: a flag token resolves to its value" {
    _flag_fn() { :; }
    knit_register_claim "flagclaim" "_flag_fn" "verbose is @v"
    knit_with_flag "v" "Verbose flag."
    knit_done
    local cmd
    _knit_command_mangle cmd "claim:flagclaim"
    local out
    _knit_claim_render out "verbose is @v" "${cmd}" --v true
    [ "${out}" = "verbose is true" ]
}

# ---------- glyph / time helpers ----------

@test "glyph: maps each verdict (and an unexpected label) to a marker" {
    local g c
    _knit_claim_glyph g c holds;        [ "${g}" = "✓" ]; [ "${c}" = "green" ]
    _knit_claim_glyph g c refuted;      [ "${g}" = "✗" ]; [ "${c}" = "red" ]
    _knit_claim_glyph g c insufficient; [ "${g}" = "?" ]; [ "${c}" = "yellow" ]
    _knit_claim_glyph g c bogus;        [ "${g}" = "?" ]; [ "${c}" = "yellow" ]
}

@test "row time: a non-uuid id yields an empty time" {
    local t
    _knit_claim_row_time t "not-a-uuid"
    [ -z "${t}" ]
}

@test "claim list: a claim with no condition parameters shows no binding bracket" {
    export _KNIT_UUIDV7_MONOTONIC=1
    _np_fn() { knit_output ok 1; return 0; }
    knit_register_claim "noparam" "_np_fn" "Always true (@ok)."
    knit_with_output "ok:integer" "A measured flag." --unset "0"
    knit_done
    knit claim check --record -- noparam >/dev/null
    run knit claim list --type noparam
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "noparam" ]
    [[ "${lines[1]}" == "  ✓ Always true (1)."* ]]
    [[ "${lines[1]}" != *"["* ]]
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
    knit_with_output   "s:integer" "Margin." --unset "0"
    knit_done

    _refute_fn() { knit_output s -3; return 1; }
    knit_register_claim "a-refutes" "_refute_fn" "A beats B by @s percent on @d."
    knit_with_required "d:string"  "Dataset."
    knit_with_output   "s:integer" "Margin." --unset "0"
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

# ---------- claim check --record ----------

@test "claim check --record writes exactly one row with statement and verdict" {
    _register_check_claims
    run knit claim check --record -- a-holds --d cifar10
    [ "$status" -eq 0 ]
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM a_holds;")
    [ "${n}" -eq 1 ]
    local row
    row=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT d, s, __verdict__, __statement__ FROM a_holds;")
    [ "${row}" = "cifar10|18|holds|A beats B by 18 percent on cifar10." ]
}

@test "claim check without --record writes no row" {
    _register_check_claims
    run knit claim check -- a-holds --d cifar10
    [ "$status" -eq 0 ]
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM a_holds;")
    [ "${n}" -eq 0 ]
}

@test "claim check --record appends on repeated records" {
    _register_check_claims
    knit claim check --record -- a-holds --d cifar10 >/dev/null
    knit claim check --record -- a-holds --d mnist >/dev/null
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM a_holds;")
    [ "${n}" -eq 2 ]
}

@test "claim check --record records the refuted verdict" {
    _register_check_claims
    run knit claim check --record -- a-refutes --d mnist
    [ "$status" -eq 1 ]
    local v
    v=$(sqlite3 "${_KNIT_DATABASE}" "SELECT __verdict__ FROM a_refutes;")
    [ "${v}" = "refuted" ]
}

@test "claim check --record records the insufficient verdict and statement" {
    _register_check_claims
    run knit claim check --record -- a-insuff --d tiny
    [ "$status" -eq 2 ]
    local v s
    v=$(sqlite3 "${_KNIT_DATABASE}" "SELECT __verdict__ FROM a_insuff;")
    s=$(sqlite3 "${_KNIT_DATABASE}" "SELECT __statement__ FROM a_insuff;")
    [ "${v}" = "insufficient" ]
    [ "${s}" = "A beats B on tiny" ]
}

@test "claim check --record with a checker error records no row" {
    _register_check_claims
    run knit claim check --record -- a-errors --d tiny
    [ "$status" -eq 3 ]
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM a_errors;")
    [ "${n}" -eq 0 ]
}

@test "claim check --record honors KNIT_DISABLE_RECORDING" {
    _register_check_claims
    KNIT_DISABLE_RECORDING=true run knit claim check --record -- a-holds --d cifar10
    [ "$status" -eq 0 ]
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM a_holds;")
    [ "${n}" -eq 0 ]
}

@test "a claim cannot be invoked directly (only through claim check)" {
    _register_check_claims
    run knit claim a-holds --d cifar10
    [ "$status" -ne 0 ]
    [[ "$output" == *"not invoked directly"* ]]
}

@test "the claim table carries the framework columns but no __exit_status__" {
    _register_check_claims
    local cols
    cols=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT name FROM pragma_table_info('a_holds');" | tr '\n' ',')
    [[ "${cols}" == *"__statement__"* ]]
    [[ "${cols}" == *"__verdict__"* ]]
    [[ "${cols}" != *"__exit_status__"* ]]
}

# ---------- claim list ----------
#
# "newest-first" is ordered by rowid (the table's insertion order), so it is
# deterministic regardless of how the uuidv7 ids happen to sort.

_seed_list_claims() {
    export _KNIT_UUIDV7_MONOTONIC=1
    _lh() { knit_output s 18; return 0; }
    knit_register_claim "a-holds" "_lh" "A beats B by @s percent on @d."
    knit_with_required "d:string"  "Dataset."
    knit_with_output   "s:integer" "Margin." --unset "0"
    knit_done
    _lr() { knit_output s -3; return 1; }
    knit_register_claim "a-ref" "_lr" "A beats B by @s percent on @d."
    knit_with_required "d:string"  "Dataset."
    knit_with_output   "s:integer" "Margin." --unset "0"
    knit_done
    _le() { :; }
    knit_register_claim "never-run" "_le" "A never evaluated on @d."
    knit_with_required "d:string" "Dataset."
    knit_done
}

@test "claim list: a declared but unrecorded claim is shown" {
    _seed_list_claims
    run knit claim list --type never-run
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "never-run" ]
    [[ "${lines[1]}" == *"(no recorded evaluations)"* ]]
}

@test "claim list: recorded rows show marker, statement, binding and group header" {
    _seed_list_claims
    knit claim check --record -- a-holds --d cifar10 >/dev/null
    run knit claim list --type a-holds
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "a-holds" ]
    [[ "${lines[1]}" == "  ✓ A beats B by 18 percent on cifar10.  [d=cifar10]  "* ]]
}

@test "claim list: rows are newest-first within a claim" {
    _seed_list_claims
    knit claim check --record -- a-holds --d first  >/dev/null
    knit claim check --record -- a-holds --d second >/dev/null
    run knit claim list --type a-holds
    [ "$status" -eq 0 ]
    # The later record (second) is listed before the earlier (first).
    [[ "${lines[1]}" == *"on second."* ]]
    [[ "${lines[2]}" == *"on first."* ]]
}

@test "claim list: a refuted row shows the cross marker" {
    _seed_list_claims
    run knit claim check --record -- a-ref --d mnist
    [ "$status" -eq 1 ]
    run knit claim list --type a-ref
    [ "$status" -eq 0 ]
    [[ "${lines[1]}" == "  ✗ A beats B by -3 percent on mnist."* ]]
}

@test "claim list: no --name lists every declared claim, grouped" {
    _seed_list_claims
    knit claim check --record -- a-holds --d cifar10 >/dev/null
    run knit claim list
    [ "$status" -eq 0 ]
    [[ "$output" == *"a-holds"* ]]
    [[ "$output" == *"a-ref"* ]]
    [[ "$output" == *"never-run"* ]]
    [[ "$output" == *"(no recorded evaluations)"* ]]
}

@test "claim list: --name with an unknown claim is fatal" {
    _seed_list_claims
    run knit claim list --type no-such-claim
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown claim"* ]]
}

@test "claim list: with no claims declared reports so" {
    run knit claim list
    [ "$status" -eq 0 ]
    [[ "$output" == *"No claims are declared"* ]]
}

@test "claim list: the time column is decoded from the row id" {
    _seed_list_claims
    knit claim check --record -- a-holds --d cifar10 >/dev/null
    run knit claim list --type a-holds
    [ "$status" -eq 0 ]
    # A YYYY-MM-DD HH:MM:SS stamp ends the row line.
    [[ "${lines[1]}" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}
