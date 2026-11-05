#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
}

# --- _knit_progress_bar_render: whole-cell fill, failed-first ----------------

@test "render: all remaining is all spaces" {
    local out=""
    _knit_progress_bar_render out 40 0 0 0 6 --no-color
    [ "${out}" = "$(printf '%40s' '')" ]
    [ "${#out}" -eq 40 ]
}

@test "render: all completed fills the field" {
    local out=""
    _knit_progress_bar_render out 40 6 0 0 0 --no-color
    [ "${out}" = "$(printf '%.0s#' {1..40})" ]
}

@test "render: mixed success sums to exactly the width" {
    local out=""
    _knit_progress_bar_render out 40 3 1 0 2 --no-color
    [ "${#out}" -eq 40 ]
    # failed=0, so the fill is completed (#) then running (:) then spaces.
    [[ "${out}" == '####'*':'*'   '* ]]
}

@test "render: failed section leads the bar" {
    local out=""
    _knit_progress_bar_render out 40 3 1 1 1 --no-color
    [ "${#out}" -eq 40 ]
    # First cell must be the failed glyph.
    [ "${out:0:1}" = "#" ]
    # It must contain a running run (:) somewhere after the leading #'s.
    [[ "${out}" == *":"* ]]
}

@test "render: a single failed job is visible (>= 1 cell) in a large total" {
    local out=""
    _knit_progress_bar_render out 40 0 0 1 99 --no-color
    [ "${out:0:1}" = "#" ]
    [ "${#out}" -eq 40 ]
}

@test "render: a single running job is visible (>= 1 cell) in a large total" {
    local out=""
    _knit_progress_bar_render out 40 0 1 0 99 --no-color
    [ "${out:0:1}" = ":" ]
    [ "${#out}" -eq 40 ]
}

@test "render: width is respected across a sweep of counts and widths" {
    local w out
    for w in 10 20 37 80; do
        for spec in "3 1 0 2" "1 1 1 3" "5 0 1 0" "0 2 0 8" "9 9 9 9"; do
            # shellcheck disable=SC2086 # intentional word split of the tuple
            set -- ${spec}
            out=""
            _knit_progress_bar_render out "${w}" "$1" "$2" "$3" "$4" --no-color
            [ "${#out}" -eq "${w}" ]
        done
    done
}

@test "render: --no-color emits ASCII glyphs and no ANSI" {
    local out=""
    _knit_progress_bar_render out 20 3 1 1 1 --no-color
    # No escape byte present at all.
    [[ "${out}" != *$'\033'* ]]
    [[ "${out}" == *"#"* ]]
    [[ "${out}" == *":"* ]]
}

@test "render: truecolor tier emits 24-bit brand escapes" {
    local out=""
    KNIT_TRUECOLOR=1 KNIT_FORCE_16COLOR="" \
        _knit_progress_bar_render out 12 0 0 12 0
    # failed section -> knit magenta #b83a83
    [[ "${out}" == *$'\033[38;2;184;58;131m'* ]]
}

@test "render: 16-color tier emits basic ANSI fallback" {
    local out=""
    KNIT_FORCE_16COLOR=1 \
        _knit_progress_bar_render out 12 12 0 0 0
    # completed section -> dark purple falls back to blue (34)
    [[ "${out}" == *$'\033[34m'* ]]
    [[ "${out}" != *$'\033[38;2;'* ]]
}

# --- _knit_progress_bar_legend ----------------------------------------------

@test "legend: no-color order is failed, done, running" {
    local out=""
    _knit_progress_bar_legend out --no-color
    [ "${out}" = "  # failed   # done   : running" ]
}

@test "legend: colored form carries brand escapes and the section labels" {
    local out=""
    KNIT_TRUECOLOR=1 _knit_progress_bar_legend out
    # Brand magenta for the failed glyph.
    [[ "${out}" == *$'\033[38;2;184;58;131m'* ]]
    # Labels present and in order.
    [[ "${out}" == *"failed"*"done"*"running"* ]]
}

# --- _knit_progress_bar_counts ----------------------------------------------

@test "counts: bare line, fail field shown only when failures > 0" {
    local out=""
    _knit_progress_bar_counts out 3 1 1 1
    [ "${out}" = "3 done  1 run  1 fail  1 left  (6)  66%" ]
}

@test "counts: no fail field when there are no failures" {
    local out=""
    _knit_progress_bar_counts out 3 1 0 2
    [ "${out}" = "3 done  1 run  2 left  (6)  50%" ]
}

@test "counts: percent is floor(100*(completed+failed)/total)" {
    local out=""
    _knit_progress_bar_counts out 2 1 0 3
    # (2+0)/6 = 33.3 -> 33
    [[ "${out}" == *"(6)  33%" ]]
}

@test "counts: --label prefixes a fixed-width label column" {
    local out=""
    _knit_progress_bar_counts out 2 1 0 3 --label "current"
    [[ "${out}" == "  current   "*"2 done  1 run  3 left  (6)  33%" ]]
}

@test "counts: all zero is a safe 0% with no division error" {
    local out=""
    _knit_progress_bar_counts out 0 0 0 0
    [[ "${out}" == *"(0)  0%" ]]
}
