#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _KNIT_IS_BOOTSTRAPPED="1"

    # A command with one optional parameter whose description is long enough to
    # wrap when a wide terminal is forced.
    knit_register knit_empty "wr" "A wrapping demo command."
    knit_with_optional "seed:integer" "0" \
        "the random seed used for the Monte Carlo sampling across all of the ranks"
    knit_done
}

teardown() {
    knit_test_db_teardown
}

# ---------- _knit_terminal_width ----------

@test "terminal width is 0 when stdout is not a terminal" {
    _knit_stdout_is_terminal() { return 1; }
    run _knit_terminal_width
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "terminal width is 0 when stty yields no usable value" {
    _knit_stdout_is_terminal() { return 0; }
    # A non-numeric "stty size" must be rejected as unusable.
    stty() { printf 'garbage\n'; }
    run _knit_terminal_width
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# ---------- _knit_help_render_entry: single-line fallback ----------

@test "render entry falls back to a single line when width is 0" {
    run _knit_help_render_entry 0 "  --x  [req] " 13 6 "one two three"
    [ "$status" -eq 0 ]
    [ "$output" = "  --x  [req] one two three" ]
}

@test "render entry falls back to a single line when the column is too narrow" {
    # width - indent = 14, below the minimum of 24, so no wrapping.
    run _knit_help_render_entry 20 "HEAD" 4 6 "aaa bbb ccc"
    [ "$status" -eq 0 ]
    [ "$output" = "HEADaaa bbb ccc" ]
}

@test "render entry with an empty description prints the head alone" {
    run _knit_help_render_entry 40 "HEAD" 4 4 ""
    [ "$status" -eq 0 ]
    [ "$output" = "HEAD" ]
}

# ---------- _knit_help_render_entry: wrapping ----------

@test "render entry wraps at word boundaries with a hanging indent" {
    run _knit_help_render_entry 30 "HEAD______" 10 4 \
        "aaaa bbbb cccc dddd eeee ffff"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "HEAD______aaaa bbbb cccc dddd" ]
    [ "${lines[1]}" = "    eeee ffff" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "render entry keeps an over-long word whole on its own line" {
    # head_len 28, so the first word starts near the right margin and is placed
    # regardless (at least one word per line); the next word wraps.
    local head
    printf -v head "%*s" 28 ""
    run _knit_help_render_entry 30 "${head}" 28 4 "abcdefghij klm"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "${head}abcdefghij" ]
    [ "${lines[1]}" = "    klm" ]
}

# ---------- integration through --help ----------

@test "a long option description wraps under the annotation column on a wide TTY" {
    _knit_terminal_width() { printf '60\n'; }
    run _knit_print_command_usage "wr"
    [ "$status" -eq 0 ]
    # --seed <value> is the widest option (14), so max_opt_length is 14 and the
    # annotation column (and continuation indent) is 2 + 14 + 2 = 18.
    local pad
    printf -v pad "%*s" 18 ""
    # A continuation line begins with exactly 18 spaces followed by a word.
    [[ "$output" == *$'\n'"${pad}"[A-Za-z]* ]]
    # The description does not sit entirely on one line.
    [[ "$output" != *"[default: '0'] the random seed used for the Monte Carlo sampling across all of the ranks"* ]]
}

@test "the same option renders on one line when width is unknown" {
    _knit_terminal_width() { printf '0\n'; }
    run _knit_print_command_usage "wr"
    [ "$status" -eq 0 ]
    # Whole description on the single option line (today's layout preserved).
    [[ "$output" == *"[default: '0'] the random seed used for the Monte Carlo sampling across all of the ranks"* ]]
    local pad
    printf -v pad "%*s" 18 ""
    [[ "$output" != *$'\n'"${pad}"[A-Za-z]* ]]
}
