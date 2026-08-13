# shellcheck shell=bash
#
# Shared helpers for the LIVE AI tests (tests/ai/test_*.sh).
#
# Unlike the curl-stubbed unit tests in tests/test_ai*.sh, these drive knit's
# `ai` commands against a REAL large language model served locally by Ollama's
# OpenAI-compatible endpoint (http://localhost:11434/v1). They are opt-in and are
# never part of `make check-unit`: the unit glob `tests/test_*.sh` is
# non-recursive, so nothing under tests/ai/ is picked up there. Run them with
# `make check-ai` (see the Makefile) after starting Ollama.
#
# This file is NOT a bats test file (it does not match test_*.sh), so it is never
# executed as a test; test files source it from their own setup().
#
# The helpers assume bats runs with the repository root as the working directory
# (as `make check-ai` does), matching the plain `source knit.sh` used throughout
# the suite.

# Model / endpoint knobs. Overridable from the environment; CI pins them at the
# workflow level so the model is chosen in exactly one place.
: "${KNIT_AI_MODEL:=qwen2.5:7b-instruct-q4_K_M}"
: "${KNIT_AI_BASE_URL:=http://localhost:11434/v1}"
: "${OLLAMA_API_KEY:=ollama}"   # Ollama ignores it; knit requires it non-empty.

# Skip the current test unless live AI testing is explicitly enabled AND a model
# server is actually reachable. This keeps `make check-ai` a clean no-op on a
# machine without Ollama and prevents these tests from ever running by accident.
knit_ai_live_require() {
    [[ "${KNIT_AI_LIVE:-}" == "1" ]] \
        || skip "live AI tests disabled (set KNIT_AI_LIVE=1 to enable)"
    command -v curl &>/dev/null || skip "curl not available"
    curl -fsS --max-time 5 "${KNIT_AI_BASE_URL%/}/models" >/dev/null 2>&1 \
        || skip "no OpenAI-compatible server reachable at ${KNIT_AI_BASE_URL}"
}

# Source knit.sh, wire up a throwaway database (via the shared unit harness), and
# point knit's AI provider at the local Ollama endpoint. Only the LLM call is
# live; the database is the same fast in-repo test DB the unit tests use.
knit_ai_live_setup() {
    knit_ai_live_require

    # shellcheck source=tests/setup_teardown.sh
    source "${BATS_TEST_DIRNAME}/../setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    KNIT_SCRIPT_NAME="my-exp.sh"
    _knit_create_metadata_table

    # Make the API-key env var visible to the knit subshells and store the
    # provider config through the real code path (as `ai init` / bootstrap would).
    export OLLAMA_API_KEY
    _knit_ai_store_config \
        "OLLAMA_API_KEY" "" "" "${KNIT_AI_BASE_URL}" "${KNIT_AI_MODEL}" "true"
}

# Tear down the throwaway database created by knit_ai_live_setup. Safe to call
# even when a test skipped before the DB was set up (e.g. Ollama unreachable),
# in which case the unit teardown helper is not yet defined.
knit_ai_live_teardown() {
    if declare -F knit_test_db_teardown >/dev/null; then
        knit_test_db_teardown
    fi
}

# Seed a small, deterministic table the model can be asked verifiable questions
# about. Ground truths: 3 rows; sum(samples)=350; max(samples)=200; 2 rows have
# app='montecarlo'.
knit_ai_live_seed_runs() {
    _knit_sqlite3_write "CREATE TABLE runs(id TEXT, app TEXT, samples INT);"
    _knit_sqlite3_write \
        "INSERT INTO runs VALUES('r1','montecarlo',100),('r2','montecarlo',200),('r3','render',50);"
}

# Run a command up to KNIT_AI_RETRIES times (default 2), succeeding as soon as its
# stdout contains the needle (case-insensitive). Absorbs the occasional bad
# generation from a small quantized model without masking a genuinely wrong
# answer. Echoes the last attempt's stdout; returns 0 if the needle appeared.
#
# Usage: knit_ai_expect_contains <needle> <command> [args...]
knit_ai_expect_contains() {
    local needle="$1"; shift
    local n="${KNIT_AI_RETRIES:-2}" i out restore
    restore="$(shopt -p nocasematch)"
    shopt -s nocasematch
    out=""
    for (( i = 1; i <= n; i++ )); do
        out="$("$@" 2>/dev/null)" || true
        if [[ "${out}" == *"${needle}"* ]]; then
            printf '%s\n' "${out}"
            eval "${restore}"
            return 0
        fi
    done
    printf '%s\n' "${out}"
    eval "${restore}"
    return 1
}
