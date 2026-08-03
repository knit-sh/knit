#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
}

# ---------- _knit_describe_json_escape ----------

@test "plain text is unchanged" {
    _knit_describe_json_escape result "hello world"
    [ "${result}" = "hello world" ]
}

@test "double quotes are escaped" {
    _knit_describe_json_escape result 'say "hi"'
    [ "${result}" = 'say \"hi\"' ]
}

@test "backslashes are escaped" {
    _knit_describe_json_escape result 'a\b'
    [ "${result}" = 'a\\b' ]
}

@test "a backslash before a quote is escaped independently" {
    _knit_describe_json_escape result 'a\"b'
    [ "${result}" = 'a\\\"b' ]
}

@test "newline becomes a short escape" {
    _knit_describe_json_escape result $'line1\nline2'
    [ "${result}" = 'line1\nline2' ]
}

@test "tab and carriage return become short escapes" {
    _knit_describe_json_escape result $'a\tb\rc'
    [ "${result}" = 'a\tb\rc' ]
}

@test "an other control character becomes a unicode escape" {
    _knit_describe_json_escape result $'a\x01b'
    expected=$(printf 'a\\u0001b')
    [ "${result}" = "${expected}" ]
}

@test "empty string stays empty" {
    _knit_describe_json_escape result ""
    [ "${result}" = "" ]
}

@test "an escaped string embeds into valid JSON" {
    local raw=$'tricky: "\\" \t and \n newline \x02'
    local escaped
    _knit_describe_json_escape escaped "${raw}"
    # Round-trip through a JSON parser and confirm the original value survives.
    local back
    back=$(printf '"%s"' "${escaped}" \
        | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin))')
    [ "${back}" = "${raw}" ]
}
