#!/usr/bin/env bats
#
# Live `ai ask` tests: knit runs the agentic tool-calling loop against a real
# model. The model can only answer the question below by calling a read-only tool
# (knit_metadata_show) and reading back a distinctive value we stored, so a
# correct answer is proof the whole tool-calling contract works end to end.
# Requires a running Ollama; skips cleanly otherwise (see tests/ai/lib.sh).

bats_require_minimum_version 1.5.0

# A value the model cannot plausibly invent, so finding it in the answer proves
# it came from the tool result rather than the model's imagination.
KNIT_AI_ASK_NEEDLE="zephyr-quokka-7"

setup() {
    source "${BATS_TEST_DIRNAME}/lib.sh"
    knit_ai_live_setup
    knit metadata store --key "campaign" --value "${KNIT_AI_ASK_NEEDLE}" >/dev/null
}

teardown() {
    knit_ai_live_teardown
}

@test "ai ask answers from a tool call and surfaces the stored value" {
    local errfile="${BATS_TEST_TMPDIR}/ask.err"
    local n="${KNIT_AI_RETRIES:-2}" i out ok=1
    shopt -s nocasematch
    for (( i = 1; i <= n; i++ )); do
        out="$(knit ai ask --verbose \
            --question "What is the value of the metadata key named campaign? Reply with just that value." \
            2>"${errfile}")" || true
        # Ground truth in the answer AND structural proof a tool was called.
        if [[ "${out}" == *"${KNIT_AI_ASK_NEEDLE}"* ]] \
            && grep -q "ai: tool call" "${errfile}"; then
            ok=0
            break
        fi
    done
    shopt -u nocasematch

    if (( ok != 0 )); then
        printf 'last answer: %s\n' "${out}" >&2
        printf 'last stderr:\n' >&2
        cat "${errfile}" >&2
    fi
    [ "${ok}" -eq 0 ]
}
