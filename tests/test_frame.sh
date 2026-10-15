#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
}

# ---------- knit_framed argument validation ----------

@test "knit_framed rejects an unknown option" {
    run knit_framed --bogus </dev/null
    [ "$status" -ne 0 ]
}

@test "knit_framed rejects an unknown flag" {
    run knit_framed --not-a-flag </dev/null
    [ "$status" -ne 0 ]
}

@test "knit_framed accepts known options and the cleanup flag" {
    run knit_framed --title hello --cleanup </dev/null
    [ "$status" -eq 0 ]
}

@test "knit_framed accepts leading positional height and width" {
    run knit_framed 10 20 --title hello </dev/null
    [ "$status" -eq 0 ]
}

# ---------- knit_framed_run ----------

@test "knit_framed_run returns the command's exit status" {
    run knit_framed_run "t" bash -c 'exit 7'
    [ "$status" -eq 7 ]
}

@test "knit_framed_run writes the command output to the trace file" {
    _KNIT_TRACE_FILE=""
    knit_framed_run "t" echo captured-line
    [ -n "${_KNIT_TRACE_FILE}" ]
    grep -q "captured-line" "${_KNIT_TRACE_FILE}"
    rm -f "${_KNIT_TRACE_FILE}"
}

@test "knit_framed_run forwards the output to stdout at trace level (non-TTY)" {
    KNIT_LOG_LEVEL=trace run knit_framed_run "t" echo hello
    [ "$status" -eq 0 ]
    [[ "$output" == *hello* ]]
}
