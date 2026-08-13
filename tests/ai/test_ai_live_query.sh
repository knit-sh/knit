#!/usr/bin/env bats
#
# Live `ai query` tests: knit generates a read-only SQL query from a natural
# language question, runs it against a real seeded table, and self-corrects on
# error. Assertions check verifiable ground truth (a known number from the
# seeded data), never the model's phrasing. Requires a running Ollama; skips
# cleanly otherwise (see tests/ai/lib.sh).

bats_require_minimum_version 1.5.0

setup() {
    source "${BATS_TEST_DIRNAME}/lib.sh"
    knit_ai_live_setup
    knit_ai_live_seed_runs
}

teardown() {
    knit_ai_live_teardown
}

@test "ai query returns the total sample count (350) from the seeded table" {
    run knit_ai_expect_contains "350" knit ai query --lang sql \
        --question "What is the total number of samples across all rows in the runs table?"
    [ "$status" -eq 0 ]
}

@test "ai query returns the maximum samples value (200)" {
    run knit_ai_expect_contains "200" knit ai query --lang sql \
        --question "What is the largest samples value in the runs table?"
    [ "$status" -eq 0 ]
}

@test "ai query --query-only emits a read-only SELECT without running it" {
    run knit_ai_expect_contains "select" knit ai query --query-only --lang sql \
        --question "How many rows are in the runs table?"
    [ "$status" -eq 0 ]
}
