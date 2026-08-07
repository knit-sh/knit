#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    KNIT_SCRIPT_NAME="my-exp.sh"
    _knit_create_metadata_table
}

teardown() {
    knit_test_db_teardown
}

# Populate the ai.* metadata keys through the shared writer used by ai init.
_store_ai() {
    # $1..$5 = api_key_env base_url_env model_env base_url model
    _knit_ai_store_config "$1" "$2" "$3" "$4" "$5" "true"
}

# ---------- _knit_ai_resolve_config ----------

@test "resolve reads key, base URL and model from the named env vars" {
    _store_ai KNIT_T_KEY KNIT_T_URL KNIT_T_MODEL "https://api.openai.com/v1" ""
    export KNIT_T_KEY="sk-secret" KNIT_T_URL="http://host/v1" KNIT_T_MODEL="gpt-x"

    local k u m
    _knit_ai_resolve_config k u m
    [ "$k" = "sk-secret" ]
    [ "$u" = "http://host/v1" ]
    [ "$m" = "gpt-x" ]
}

@test "resolve falls back to the literal base URL when the env var is unset" {
    _store_ai KNIT_T_KEY KNIT_T_URL KNIT_T_MODEL "http://literal/v1" "lit-model"
    export KNIT_T_KEY="sk-secret"
    unset KNIT_T_URL KNIT_T_MODEL

    local k u m
    _knit_ai_resolve_config k u m
    [ "$u" = "http://literal/v1" ]
    [ "$m" = "lit-model" ]
}

@test "resolve model precedence: override > env var > literal" {
    _store_ai KNIT_T_KEY "" KNIT_T_MODEL "https://api.openai.com/v1" "lit-model"
    export KNIT_T_KEY="sk-secret"

    # literal only
    unset KNIT_T_MODEL
    local k u m
    _knit_ai_resolve_config k u m
    [ "$m" = "lit-model" ]

    # env var beats literal
    export KNIT_T_MODEL="env-model"
    _knit_ai_resolve_config k u m
    [ "$m" = "env-model" ]

    # override beats both
    _knit_ai_resolve_config k u m "override-model"
    [ "$m" = "override-model" ]
}

@test "resolve fatals when the provider is not configured" {
    local k u m
    run _knit_ai_resolve_config k u m
    [ "$status" -ne 0 ]
    [[ "$output" == *"not configured"* ]]
}

@test "resolve fatals when the API key env var is empty" {
    _store_ai KNIT_T_KEY "" "" "https://api.openai.com/v1" "lit-model"
    unset KNIT_T_KEY
    local k u m
    run _knit_ai_resolve_config k u m
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty or unset"* ]]
}

@test "resolve fatals when no model can be resolved" {
    _store_ai KNIT_T_KEY "" "" "https://api.openai.com/v1" ""
    export KNIT_T_KEY="sk-secret"
    local k u m
    run _knit_ai_resolve_config k u m
    [ "$status" -ne 0 ]
    [[ "$output" == *"No AI model configured"* ]]
}

@test "resolve writes back to caller vars named like the internals (nameref shadow regression)" {
    _store_ai KNIT_T_KEY "" KNIT_T_MODEL "http://literal/v1" "lit-model"
    export KNIT_T_KEY="sk-secret" KNIT_T_MODEL="gpt-x"

    # The real callers (ai ask / ai query) pass output arguments literally named
    # api_key and base_url --- the same names as this function's internal working
    # locals. If those internals are not __-prefixed, the output nameref is
    # shadowed and the caller silently gets empty strings (which produced a
    # "curl: (3) No host part in the URL" failure on every AI request).
    local api_key base_url resolved_model
    _knit_ai_resolve_config api_key base_url resolved_model
    [ "$api_key" = "sk-secret" ]
    [ "$base_url" = "http://literal/v1" ]
    [ "$resolved_model" = "gpt-x" ]
}

# ---------- _knit_ai_chat_request (stubbed curl) ----------

# Stub curl: capture the request body and config file, then emit a canned
# response on stdout (as the real curl would with the body captured to stdout).
_stub_curl() {
    export KNIT_T_BODY_CAPTURE="${BATS_TEST_TMPDIR}/body.json"
    export KNIT_T_CFG_CAPTURE="${BATS_TEST_TMPDIR}/curl.cfg"
    export KNIT_T_CANNED="$1"
    export KNIT_T_HTTP_CODE="${2:-200}"
    curl() {
        local cfg="" out=""
        while (( $# )); do
            case "$1" in
                -K) cfg="$2"; shift 2 ;;
                -o) out="$2"; shift 2 ;;
                *)  shift ;;
            esac
        done
        cp "${cfg}" "${KNIT_T_CFG_CAPTURE}"
        local bf
        bf=$(sed -n 's/^data-binary = "@\(.*\)"$/\1/p' "${cfg}")
        [[ -n "${bf}" ]] && cp "${bf}" "${KNIT_T_BODY_CAPTURE}"
        # Mirror real curl -o/-w: body to the file, status code to stdout.
        if [[ -n "${out}" ]]; then
            printf '%s' "${KNIT_T_CANNED}" > "${out}"
            printf '%s' "${KNIT_T_HTTP_CODE}"
        else
            printf '%s' "${KNIT_T_CANNED}"
        fi
    }
}

@test "chat request builds a well-formed body with model and messages" {
    _stub_curl '{"choices":[{"message":{"role":"assistant","content":"hi"}}]}'
    local msgs='[{"role":"user","content":"hello"}]'

    run _knit_ai_chat_request "http://host/v1" "sk-secret" "gpt-x" "${msgs}"
    [ "$status" -eq 0 ]

    [ "$(jq -r '.model' "${KNIT_T_BODY_CAPTURE}")" = "gpt-x" ]
    [ "$(jq -r '.messages[0].content' "${KNIT_T_BODY_CAPTURE}")" = "hello" ]
    # No tools passed => no tools key.
    [ "$(jq 'has("tools")' "${KNIT_T_BODY_CAPTURE}")" = "false" ]
}

@test "chat request includes tools when a tools array is given" {
    _stub_curl '{"choices":[{"message":{"content":"ok"}}]}'
    local msgs='[{"role":"user","content":"hi"}]'
    local tools='[{"type":"function","function":{"name":"knit_describe"}}]'

    run _knit_ai_chat_request "http://host/v1" "sk-secret" "gpt-x" "${msgs}" "${tools}"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tools[0].function.name' "${KNIT_T_BODY_CAPTURE}")" = "knit_describe" ]
}

@test "chat request returns the raw provider response on stdout" {
    local canned='{"choices":[{"message":{"role":"assistant","content":"the answer"}}]}'
    _stub_curl "${canned}"

    run _knit_ai_chat_request "http://host/v1" "sk-secret" "gpt-x" '[{"role":"user","content":"q"}]'
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.choices[0].message.content')" = "the answer" ]
}

@test "chat request surfaces a provider error and fails" {
    _stub_curl '{"error":{"message":"invalid api key","type":"auth_error"}}'

    run _knit_ai_chat_request "http://host/v1" "sk-secret" "gpt-x" '[{"role":"user","content":"q"}]'
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid api key"* ]]
    [[ "$output" == *"auth_error"* ]]
}

@test "chat request surfaces a non-2xx HTTP status with the response body" {
    # A wrong base URL yields a 404 whose body is not an OpenAI error object;
    # the status and body must be reported instead of an opaque later failure.
    _stub_curl '{"detail":"Not Found"}' 404

    run _knit_ai_chat_request "http://host/chat/completions" "sk" "gpt-x" '[{"role":"user","content":"q"}]'
    [ "$status" -ne 0 ]
    [[ "$output" == *"HTTP 404"* ]]
    [[ "$output" == *"Not Found"* ]]
}

@test "chat request redacts the API key from the trace and argv" {
    _stub_curl '{"choices":[{"message":{"content":"ok"}}]}'

    KNIT_LOG_LEVEL=trace run _knit_ai_chat_request \
        "http://host/v1" "sk-topsecret" "gpt-x" '[{"role":"user","content":"q"}]'
    [ "$status" -eq 0 ]
    # The trace must not leak the key, and must show the redaction marker.
    [[ "$output" != *"sk-topsecret"* ]]
    [[ "$output" == *"<redacted>"* ]]
    # The key lives only in the mode-600 config file, never on the command line.
    grep -q "Authorization: Bearer sk-topsecret" "${KNIT_T_CFG_CAPTURE}"
}
