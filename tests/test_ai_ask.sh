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

# Stub curl to return a canned response per call, in order, and capture each
# request body to a numbered file so a later turn's payload can be inspected.
_stub_curl_seq() {
    export KNIT_T_SEQ="${BATS_TEST_TMPDIR}/seq"
    rm -rf "${KNIT_T_SEQ}"; mkdir -p "${KNIT_T_SEQ}"
    local i=1 r
    for r in "$@"; do
        printf '%s' "${r}" > "${KNIT_T_SEQ}/resp_${i}"
        (( i++ ))
    done
    printf '0' > "${KNIT_T_SEQ}/n"
    curl() {
        local cfg="" out=""
        while (( $# )); do
            case "$1" in
                -K) cfg="$2"; shift 2 ;;
                -o) out="$2"; shift 2 ;;
                *)  shift ;;
            esac
        done
        local n
        n=$(<"${KNIT_T_SEQ}/n"); n=$(( n + 1 ))
        printf '%s' "${n}" > "${KNIT_T_SEQ}/n"
        local bf
        bf=$(sed -n 's/^data-binary = "@\(.*\)"$/\1/p' "${cfg}")
        [[ -n "${bf}" ]] && cp "${bf}" "${KNIT_T_SEQ}/body_${n}"
        # Mirror real curl -o/-w: body to the file, status code to stdout.
        if [[ -n "${out}" ]]; then
            cat "${KNIT_T_SEQ}/resp_${n}" > "${out}"
            printf '200'
        else
            cat "${KNIT_T_SEQ}/resp_${n}"
        fi
    }
}

# A canned assistant message that requests one knit_describe tool call.
_TOOLCALL='{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"knit_describe","arguments":"{}"}}]}}]}'

# ---------- _knit_ai_loop ----------

@test "loop terminates on a no-tool-calls response and prints the answer" {
    _stub_curl_seq '{"choices":[{"message":{"role":"assistant","content":"the answer is 42"}}]}'
    run _knit_ai_loop "http://h/v1" "sk" "gpt-x" "q?" "sys" 8 false false
    [ "$status" -eq 0 ]
    [[ "$output" == *"the answer is 42"* ]]
}

@test "loop feeds a tool result back and reaches the final answer" {
    _knit_ai_dispatch_tool() { printf 'TOOLRESULT\n'; }
    _stub_curl_seq "${_TOOLCALL}" \
        '{"choices":[{"message":{"role":"assistant","content":"final answer"}}]}'

    run _knit_ai_loop "http://h/v1" "sk" "gpt-x" "q?" "sys" 8 false false
    [ "$status" -eq 0 ]
    [[ "$output" == *"final answer"* ]]

    # Exactly two provider calls were made.
    [ "$(cat "${KNIT_T_SEQ}/n")" = "2" ]
    # The second request carried both the assistant tool_call and the tool result.
    local body2; body2=$(cat "${KNIT_T_SEQ}/body_2")
    [ "$(printf '%s' "${body2}" | jq -r '.messages[-1].role')" = "tool" ]
    [ "$(printf '%s' "${body2}" | jq -r '.messages[-1].tool_call_id')" = "call_1" ]
    [ "$(printf '%s' "${body2}" | jq -r '.messages[-1].content')" = "TOOLRESULT" ]
    [ "$(printf '%s' "${body2}" | jq -r '.messages[-2].tool_calls[0].id')" = "call_1" ]
}

@test "loop warns and fails when it hits the iteration cap" {
    _knit_ai_dispatch_tool() { printf 'R\n'; }
    _stub_curl_seq "${_TOOLCALL}" "${_TOOLCALL}" "${_TOOLCALL}"

    run _knit_ai_loop "http://h/v1" "sk" "gpt-x" "q?" "sys" 2 false false
    [ "$status" -ne 0 ]
    [[ "$output" == *"max-iterations"* ]]
    # Stopped after exactly the cap, not more.
    [ "$(cat "${KNIT_T_SEQ}/n")" = "2" ]
}

@test "loop --raw prints the raw final message JSON" {
    _stub_curl_seq '{"choices":[{"message":{"role":"assistant","content":"hello"}}]}'
    run _knit_ai_loop "http://h/v1" "sk" "gpt-x" "q?" "sys" 8 true false
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.role')" = "assistant" ]
    [ "$(printf '%s' "$output" | jq -r '.content')" = "hello" ]
}

@test "loop --verbose streams tool calls and results to stderr" {
    _knit_ai_dispatch_tool() { printf 'RESULT-TEXT\n'; }
    _stub_curl_seq "${_TOOLCALL}" \
        '{"choices":[{"message":{"content":"done"}}]}'

    run _knit_ai_loop "http://h/v1" "sk" "gpt-x" "q?" "sys" 8 false true
    [ "$status" -eq 0 ]
    # run merges stderr into $output, so the verbose stream is visible here.
    [[ "$output" == *"tool call knit_describe"* ]]
    [[ "$output" == *"RESULT-TEXT"* ]]
}

# ---------- _knit_ai_default_system_prompt ----------

@test "default system prompt names the experiment and seeds the command list" {
    run _knit_ai_default_system_prompt
    [ "$status" -eq 0 ]
    [[ "$output" == *"my-exp.sh"* ]]
    [[ "$output" == *"read-only"* ]]
    # The compact describe summary is seeded (e.g. the bootstrap command line).
    [[ "$output" == *"- bootstrap:"* ]]
    [[ "$output" == *"- ai ask:"* ]]
}

# ---------- ai ask (end to end via the dispatcher, stubbed curl) ----------

@test "ai ask resolves config, runs the loop, and prints the answer" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _stub_curl_seq '{"choices":[{"message":{"role":"assistant","content":"the answer"}}]}'

    run knit ai ask --question "what commands exist?"
    [ "$status" -eq 0 ]
    [[ "$output" == *"the answer"* ]]
}

@test "ai ask fatals cleanly when the provider is not configured" {
    run knit ai ask --question "hi"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not configured"* ]]
}

@test "ai ask honors a custom --system prompt (no describe seed)" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _stub_curl_seq '{"choices":[{"message":{"content":"ok"}}]}'

    run knit ai ask --question "hi" --system "You are terse."
    [ "$status" -eq 0 ]
    # The first request's system message is exactly the override.
    local body1; body1=$(cat "${KNIT_T_SEQ}/body_1")
    [ "$(printf '%s' "${body1}" | jq -r '.messages[0].content')" = "You are terse." ]
}
