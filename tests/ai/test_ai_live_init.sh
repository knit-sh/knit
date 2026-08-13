#!/usr/bin/env bats
#
# Live `ai init` round-trip: configure the provider through the real `ai init`
# command (not the harness shortcut), then prove that a real `ai query` resolves
# and uses that stored config against a live model. Requires a running Ollama;
# skips cleanly otherwise (see tests/ai/lib.sh).

bats_require_minimum_version 1.5.0

setup() {
    source "${BATS_TEST_DIRNAME}/lib.sh"
    knit_ai_live_setup_noconfig
    knit_ai_live_seed_runs
}

teardown() {
    knit_ai_live_teardown
}

@test "ai init config drives a live ai query" {
    run knit ai init --force \
        --api-key-env OLLAMA_API_KEY \
        --base-url "${KNIT_AI_BASE_URL}" \
        --model "${KNIT_AI_MODEL}"
    [ "$status" -eq 0 ]

    run knit_ai_expect_contains "350" knit ai query --lang sql \
        --question "What is the total number of samples across all rows in the runs table?"
    [ "$status" -eq 0 ]
}
