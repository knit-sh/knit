#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # Force stdout to look like a terminal so highlighting is exercised; tests
    # that need the non-TTY path override this locally.
    _knit_stdout_is_terminal() { return 0; }

    # A small tree of top-level commands:
    #   shl_plain  no highlight
    #   shl_bold   highlight predicate returns 0 -> bold
    #   shl_off    highlight predicate returns non-zero -> plain
    knit_register knit_empty "shl_plain" "A plain command."
    knit_done
    knit_register knit_empty "shl_bold" "A bold command."
    knit_highlight_if _shl_yes
    knit_done
    knit_register knit_empty "shl_off" "An unhighlighted command."
    knit_highlight_if _shl_no
    knit_done
}

teardown() {
    knit_test_db_teardown
}

_shl_yes() { return 0; }
_shl_no() { return 1; }

# ANSI escapes emitted by the renderer.
B=$'\033[1m'
R=$'\033[0m'

@test "a highlighted subcommand name is bold on a TTY with NO_COLOR unset" {
    unset NO_COLOR
    run _knit_print_command_usage "__main__"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${B}shl_bold${R}"* ]]
}

@test "a non-highlighted subcommand name is printed plain" {
    unset NO_COLOR
    run _knit_print_command_usage "__main__"
    [[ "$output" == *"shl_off"* ]]
    [[ "$output" != *"${B}shl_off${R}"* ]]
    [[ "$output" != *"${B}shl_plain${R}"* ]]
}

@test "highlight alignment pads on the plain name length" {
    unset NO_COLOR
    run _knit_print_command_usage "__main__"
    # Longest name is shl_plain (9); shl_bold (8) is padded by one leading space
    # so that the bold name still right-justifies into the plain column: two
    # indent spaces + one pad space precede the bold escape.
    [[ "$output" == *"   ${B}shl_bold${R}   A bold command."* ]]
}

@test "no highlight escapes when stdout is not a TTY" {
    unset NO_COLOR
    _knit_stdout_is_terminal() { return 1; }
    run _knit_print_command_usage "__main__"
    [[ "$output" == *"shl_bold"* ]]
    [[ "$output" != *"${B}"* ]]
}

@test "no highlight escapes when NO_COLOR is set" {
    export NO_COLOR=1
    run _knit_print_command_usage "__main__"
    unset NO_COLOR
    [[ "$output" == *"shl_bold"* ]]
    [[ "$output" != *"${B}"* ]]
}

@test "no highlight escapes when NO_COLOR is set to the empty string" {
    export NO_COLOR=
    run _knit_print_command_usage "__main__"
    unset NO_COLOR
    [[ "$output" == *"shl_bold"* ]]
    [[ "$output" != *"${B}"* ]]
}
