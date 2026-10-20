#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
}

# ---------- _knit_search_parse_literal: list ----------

@test "parse a list descriptor" {
    local -A desc; local values
    _knit_search_parse_literal desc values '{a,b,c}'
    [ "${desc[kind]}" = "list" ]
    [ "${#values[@]}" -eq 3 ]
    [ "${values[0]}" = "a" ]
    [ "${values[1]}" = "b" ]
    [ "${values[2]}" = "c" ]
}

@test "parse a single-value list descriptor" {
    local -A desc; local values
    _knit_search_parse_literal desc values '{only}'
    [ "${desc[kind]}" = "list" ]
    [ "${#values[@]}" -eq 1 ]
    [ "${values[0]}" = "only" ]
}

@test "an empty list descriptor is fatal" {
    local -A desc; local values
    run _knit_search_parse_literal desc values '{}'
    [ "$status" -eq 1 ]
}

# ---------- _knit_search_parse_literal: range ----------

@test "parse a bare range descriptor" {
    local -A desc; local values
    _knit_search_parse_literal desc values '[2..12]'
    [ "${desc[kind]}" = "range" ]
    [ "${desc[lo]}" = "2" ]
    [ "${desc[hi]}" = "12" ]
    [ "${desc[step]}" = "" ]
}

@test "parse a range descriptor with a step" {
    local -A desc; local values
    _knit_search_parse_literal desc values '[0..10:2]'
    [ "${desc[kind]}" = "range" ]
    [ "${desc[lo]}" = "0" ]
    [ "${desc[hi]}" = "10" ]
    [ "${desc[step]}" = "2" ]
}

@test "parse a real range with a fractional step" {
    local -A desc; local values
    _knit_search_parse_literal desc values '[1e-5..1.0:0.5]'
    [ "${desc[kind]}" = "range" ]
    [ "${desc[lo]}" = "1e-5" ]
    [ "${desc[hi]}" = "1.0" ]
    [ "${desc[step]}" = "0.5" ]
}

@test "parse a range with negative bounds" {
    local -A desc; local values
    _knit_search_parse_literal desc values '[-5..-1]'
    [ "${desc[kind]}" = "range" ]
    [ "${desc[lo]}" = "-5" ]
    [ "${desc[hi]}" = "-1" ]
}

@test "a range missing a bound is fatal" {
    local -A desc; local values
    run _knit_search_parse_literal desc values '[1..]'
    [ "$status" -eq 1 ]
    run _knit_search_parse_literal desc values '[..9]'
    [ "$status" -eq 1 ]
}

@test "a range with three bounds is fatal" {
    local -A desc; local values
    run _knit_search_parse_literal desc values '[1..5..9]'
    [ "$status" -eq 1 ]
}

@test "a range with two steps is fatal" {
    local -A desc; local values
    run _knit_search_parse_literal desc values '[1..9:2:3]'
    [ "$status" -eq 1 ]
}

# ---------- _knit_search_parse_literal: glob and file ----------

@test "parse a glob descriptor (pattern kept verbatim, not expanded)" {
    local -A desc; local values
    _knit_search_parse_literal desc values '@glob:data/*.txt'
    [ "${desc[kind]}" = "glob" ]
    [ "${desc[glob]}" = "data/*.txt" ]
    [ "${#values[@]}" -eq 0 ]
}

@test "parse a file descriptor (read one value per line)" {
    local tmp; tmp="$(mktemp)"
    printf 'one\ntwo\nthree\n' > "${tmp}"
    local -A desc; local values
    _knit_search_parse_literal desc values "@file:${tmp}"
    rm -f "${tmp}"
    [ "${desc[kind]}" = "list" ]
    [ "${#values[@]}" -eq 3 ]
    [ "${values[0]}" = "one" ]
    [ "${values[2]}" = "three" ]
}

@test "an unreadable file descriptor is fatal" {
    local -A desc; local values
    run _knit_search_parse_literal desc values '@file:/no/such/path/xyz'
    [ "$status" -eq 1 ]
}

# ---------- _knit_search_parse_literal: rejection ----------

@test "a plain scalar is not a descriptor" {
    local -A desc; local values
    run _knit_search_parse_literal desc values 'plain'
    [ "$status" -eq 1 ]
}

# ---------- _knit_search_validate_descriptor: accepted ----------

@test "an integer range is valid" {
    local -A desc; local values
    _knit_search_parse_literal desc values '[2..12:2]'
    _knit_search_validate_descriptor desc values integer ""
}

@test "a real range accepts the --log hint" {
    local -A desc; local values
    _knit_search_parse_literal desc values '[1e-5..1.0]'
    _knit_search_validate_descriptor desc values real true
}

@test "an integer list is valid" {
    local -A desc; local values
    _knit_search_parse_literal desc values '{16,32,64}'
    _knit_search_validate_descriptor desc values integer ""
}

@test "a boolean list of true/false is valid" {
    local -A desc; local values
    _knit_search_parse_literal desc values '{true,false}'
    _knit_search_validate_descriptor desc values boolean ""
}

@test "a string glob is valid" {
    local -A desc; local values
    _knit_search_parse_literal desc values '@glob:*.txt'
    _knit_search_validate_descriptor desc values string ""
}

@test "an enum list restricted to a subset is valid" {
    knit_enum "codec" "h264" "av1" "vp9"
    local -A desc; local values
    _knit_search_parse_literal desc values '{h264,av1}'
    _knit_search_validate_descriptor desc values codec ""
}

@test "a type alias resolves before validation" {
    local -A desc; local values
    _knit_search_parse_literal desc values '[2..12]'
    _knit_search_validate_descriptor desc values int ""
}

# ---------- _knit_search_validate_descriptor: rejected ----------

@test "a range on a string parameter is fatal" {
    local -A desc; local values
    _knit_search_parse_literal desc values '[2..12]'
    run _knit_search_validate_descriptor desc values string ""
    [ "$status" -eq 1 ]
}

@test "a range on an enum parameter is fatal" {
    knit_enum "codec2" "h264" "av1"
    local -A desc; local values
    _knit_search_parse_literal desc values '[1..2]'
    run _knit_search_validate_descriptor desc values codec2 ""
    [ "$status" -eq 1 ]
}

@test "a range on a boolean parameter is fatal" {
    local -A desc; local values
    _knit_search_parse_literal desc values '[0..1]'
    run _knit_search_validate_descriptor desc values boolean ""
    [ "$status" -eq 1 ]
}

@test "a non-integer bound on an integer range is fatal" {
    local -A desc; local values
    _knit_search_parse_literal desc values '[1.5..9]'
    run _knit_search_validate_descriptor desc values integer ""
    [ "$status" -eq 1 ]
}

@test "a glob on a non-string parameter is fatal" {
    local -A desc; local values
    _knit_search_parse_literal desc values '@glob:*.dat'
    run _knit_search_validate_descriptor desc values integer ""
    [ "$status" -eq 1 ]
}

@test "a list value outside the enum domain is fatal" {
    knit_enum "codec3" "h264" "av1"
    local -A desc; local values
    _knit_search_parse_literal desc values '{h264,hevc}'
    run _knit_search_validate_descriptor desc values codec3 ""
    [ "$status" -eq 1 ]
}

@test "a non-integer value in an integer list is fatal" {
    local -A desc; local values
    _knit_search_parse_literal desc values '{16,x,64}'
    run _knit_search_validate_descriptor desc values integer ""
    [ "$status" -eq 1 ]
}

@test "the --log hint on an integer range is fatal" {
    local -A desc; local values
    _knit_search_parse_literal desc values '[2..12]'
    run _knit_search_validate_descriptor desc values integer true
    [ "$status" -eq 1 ]
}

@test "the --log hint on a list is fatal" {
    local -A desc; local values
    _knit_search_parse_literal desc values '{0.1,0.2}'
    run _knit_search_validate_descriptor desc values real true
    [ "$status" -eq 1 ]
}
