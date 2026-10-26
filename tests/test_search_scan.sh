#!/usr/bin/env bats
#
# Tests for the public knit_search_scan token classifier.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_source_knit
}

@test "the template is the downstream tokens, verbatim" {
    local -a tmpl axes raw
    local -A seen
    knit_search_scan tmpl axes raw seen "" \
        submit --walltime 00:30:00 --nodes '{1,2,4}' -- montecarlo
    [ "${tmpl[0]}" = "submit" ]
    [ "${tmpl[1]}" = "--walltime" ]
    [ "${tmpl[2]}" = "00:30:00" ]
    [ "${tmpl[3]}" = "--nodes" ]
    [ "${tmpl[4]}" = "{1,2,4}" ]
    [ "${tmpl[5]}" = "--" ]
    [ "${tmpl[6]}" = "montecarlo" ]
}

@test "literal axes carry their verbatim token text, not an enumerated list" {
    local -a tmpl axes raw
    local -A seen
    knit_search_scan tmpl axes raw seen "" \
        submit --nodes '{1,2,4}' -- montecarlo --samples '{1000,100000}' --seed '[1..3]'
    [ "${#axes[@]}" -eq 3 ]
    [ "${axes[0]}" = "literal 2 nodes" ]
    [ "${axes[1]}" = "literal 6 samples" ]
    [ "${axes[2]}" = "literal 8 seed" ]
    [ "${raw[0]}" = "{1,2,4}" ]
    [ "${raw[1]}" = "{1000,100000}" ]
    [ "${raw[2]}" = "[1..3]" ]
}

@test "@sweep and @default axes carry empty raw tokens" {
    local -a tmpl axes raw
    local -A seen
    knit_search_scan tmpl axes raw seen "" \
        submit -- train --batch '{16,64}' --layers @sweep --lr @default
    [ "${#axes[@]}" -eq 3 ]
    [ "${axes[0]}" = "literal 4 batch" ]
    [ "${axes[1]}" = "sweep 6 layers" ]
    [ "${axes[2]}" = "default 8 lr" ]
    [ "${raw[0]}" = "{16,64}" ]
    [ -z "${raw[1]}" ]
    [ -z "${raw[2]}" ]
}

@test "the seen map records how each option was specified" {
    local -a tmpl axes raw
    local -A seen
    knit_search_scan tmpl axes raw seen "" \
        submit -- train --lr @default --batch '{16,64}' --layers @sweep
    [ "${seen[lr]}" = "default" ]
    [ "${seen[batch]}" = "explicit" ]
    [ "${seen[layers]}" = "sweep" ]
}

@test "a concrete value marks its option explicit in the seen map" {
    local -a tmpl axes raw
    local -A seen
    knit_search_scan tmpl axes raw seen "" \
        submit --walltime 00:30:00 --nodes '{1,2,4}' -- montecarlo
    [ "${seen[walltime]}" = "explicit" ]
    [ "${seen[nodes]}" = "explicit" ]
}

@test "--passthrough protects a named option from being swept" {
    local -a tmpl axes raw
    local -A seen
    knit_search_scan tmpl axes raw seen "pattern" \
        scan --pattern '{foo,bar}' --threads '{1,2,4}'
    [ "${#axes[@]}" -eq 1 ]
    [ "${axes[0]}" = "literal 4 threads" ]
    [ "${raw[0]}" = "{1,2,4}" ]
    [ "${seen[pattern]}" = "explicit" ]
    [ "${tmpl[2]}" = "{foo,bar}" ]
}

@test "--passthrough protects several names and trims surrounding whitespace" {
    local -a tmpl axes raw
    local -A seen
    knit_search_scan tmpl axes raw seen " pattern , input " \
        scan --pattern '{foo,bar}' --input '{a,b}' --threads '{1,2,4}'
    # Only --threads is swept; the two whitespace-padded passthrough names protect
    # --pattern and --input, which pass through as explicit values.
    [ "${#axes[@]}" -eq 1 ]
    [ "${axes[0]}" = "literal 6 threads" ]
    [ "${raw[0]}" = "{1,2,4}" ]
    [ "${seen[pattern]}" = "explicit" ]
    [ "${seen[input]}" = "explicit" ]
    [ "${seen[threads]}" = "explicit" ]
    [ "${tmpl[2]}" = "{foo,bar}" ]
    [ "${tmpl[4]}" = "{a,b}" ]
}

@test "a swept positional is named by its index" {
    local -a tmpl axes raw
    local -A seen
    knit_search_scan tmpl axes raw seen "" render '{256,512}'
    [ "${#axes[@]}" -eq 1 ]
    [ "${axes[0]}" = "literal 1 #1" ]
    [ "${raw[0]}" = "{256,512}" ]
}

@test "the inline --opt=value form is explicit and never swept" {
    local -a tmpl axes raw
    local -A seen
    knit_search_scan tmpl axes raw seen "" render --width='{256,512}'
    [ "${#axes[@]}" -eq 0 ]
    [ "${seen[width]}" = "explicit" ]
}

@test "an unknown @ directive is a fatal" {
    run knit_search_scan tmpl axes raw seen "" render --x @bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown sweep directive"* ]]
}

@test "@glob and @file paths are classified as literal axes with verbatim raw tokens" {
    local -a tmpl axes raw
    local -A seen
    local f="${BATS_TEST_TMPDIR}/vals.txt"
    printf '%s\n' one two > "${f}"
    knit_search_scan tmpl axes raw seen "" \
        render --input "@file:${f}" --pattern "@glob:/tmp/*.txt"
    [ "${#axes[@]}" -eq 2 ]
    [ "${axes[0]}" = "literal 2 input" ]
    [ "${axes[1]}" = "literal 4 pattern" ]
    [ "${raw[0]}" = "@file:${f}" ]
    [ "${raw[1]}" = "@glob:/tmp/*.txt" ]
}

@test "hyphenated option names are normalized when naming an axis" {
    local -a tmpl axes raw
    local -A seen
    knit_search_scan tmpl axes raw seen "" run --procs-per-node '{1,2}'
    [ "${axes[0]}" = "literal 2 procs_per_node" ]
}
