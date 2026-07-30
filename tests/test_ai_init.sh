#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    _knit_create_metadata_table
}

teardown() {
    knit_test_db_teardown
}

# Read one metadata value straight from the throwaway database.
_meta() {
    sqlite3 "${_KNIT_DATABASE}" "SELECT value FROM metadata WHERE key='$1';"
}

# ---------- ai init (via the dispatcher, so defaults are injected) ----------

@test "ai init stores every env-var name it is given" {
    run knit ai init \
        --api-key-env OPENAI_API_KEY \
        --base-url-env OPENAI_BASE_URL \
        --model-env KNIT_AI_MODEL
    [ "$status" -eq 0 ]
    [ "$(_meta ai.api_key_env)" = "OPENAI_API_KEY" ]
    [ "$(_meta ai.base_url_env)" = "OPENAI_BASE_URL" ]
    [ "$(_meta ai.model_env)" = "KNIT_AI_MODEL" ]
}

@test "ai init stores literal fallbacks (base-url default, model empty)" {
    run knit ai init --api-key-env OPENAI_API_KEY
    [ "$status" -eq 0 ]
    [ "$(_meta ai.base_url)" = "https://api.openai.com/v1" ]
    [ "$(_meta ai.model)" = "" ]
}

@test "ai init records explicit literal fallbacks" {
    run knit ai init \
        --api-key-env OPENAI_API_KEY \
        --base-url http://localhost:11434/v1 \
        --model llama3
    [ "$status" -eq 0 ]
    [ "$(_meta ai.base_url)" = "http://localhost:11434/v1" ]
    [ "$(_meta ai.model)" = "llama3" ]
}

@test "ai init fails when the required --api-key-env is missing" {
    run knit ai init --base-url-env OPENAI_BASE_URL
    [ "$status" -ne 0 ]
    [ "$(_meta ai.api_key_env)" = "" ]
}

@test "ai init without --force fails when config already exists" {
    knit ai init --api-key-env FIRST_KEY
    run knit ai init --api-key-env SECOND_KEY
    [ "$status" -ne 0 ]
    [ "$(_meta ai.api_key_env)" = "FIRST_KEY" ]
}

@test "ai init --force overwrites existing config" {
    knit ai init --api-key-env FIRST_KEY
    run knit ai init --api-key-env SECOND_KEY --force
    [ "$status" -eq 0 ]
    [ "$(_meta ai.api_key_env)" = "SECOND_KEY" ]
}

@test "ai init --force leaves a single row per key" {
    knit ai init --api-key-env FIRST_KEY
    knit ai init --api-key-env SECOND_KEY --force
    local count
    count=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM metadata WHERE key='ai.api_key_env';")
    [ "$count" = "1" ]
}

# ---------- bootstrap-time --ai-* (full bootstrap with heavy steps stubbed) --

# Drive the real bootstrap body, stubbing only the from-source/network provisioning
# so it runs against the throwaway database created in setup(). The prefix dir must
# not pre-exist (bootstrap creates it and then treats the experiment as bootstrapped).
_bootstrap_with_stubs() {
    _KNIT_PREFIX="$(mktemp -du)"
    _KNIT_IS_BOOTSTRAPPED=""
    _knit_bootstrap_sqlite() { :; }
    _knit_bootstrap_jq() { :; }
    _knit_bootstrap_knitgraph() { :; }
    _knit_bootstrap_need_spack() { return 1; }
    _knit_detect_job_manager() { printf 'local'; }
    _knit_detect_launcher() { printf 'openmpi'; }
    _knit_detect_node_ncpus() { printf '1'; }
    run knit bootstrap "$@"
    rm -rf "${_KNIT_PREFIX}"
}

@test "bootstrap --ai-* writes the same ai.* keys as ai init" {
    _bootstrap_with_stubs \
        --ai-api-key-env OPENAI_API_KEY \
        --ai-base-url-env OPENAI_BASE_URL \
        --ai-model-env KNIT_AI_MODEL \
        --ai-model gpt-4o
    [ "$status" -eq 0 ]
    [ "$(_meta ai.api_key_env)" = "OPENAI_API_KEY" ]
    [ "$(_meta ai.base_url_env)" = "OPENAI_BASE_URL" ]
    [ "$(_meta ai.model_env)" = "KNIT_AI_MODEL" ]
    [ "$(_meta ai.base_url)" = "https://api.openai.com/v1" ]
    [ "$(_meta ai.model)" = "gpt-4o" ]
}

@test "bootstrap without --ai-api-key-env writes no ai.* keys" {
    _bootstrap_with_stubs
    [ "$status" -eq 0 ]
    local count
    count=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM metadata WHERE key LIKE 'ai.%';")
    [ "$count" = "0" ]
}
