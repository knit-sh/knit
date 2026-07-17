#!/usr/bin/env bats

setup() {
    source knit.sh
}

# ---------- _knit_describe_json_escape ----------

@test "plain text is unchanged" {
    result=$(_knit_describe_json_escape "hello world")
    [ "${result}" = "hello world" ]
}

@test "double quotes are escaped" {
    result=$(_knit_describe_json_escape 'say "hi"')
    [ "${result}" = 'say \"hi\"' ]
}

@test "backslashes are escaped" {
    result=$(_knit_describe_json_escape 'a\b')
    [ "${result}" = 'a\\b' ]
}

@test "a backslash before a quote is escaped independently" {
    result=$(_knit_describe_json_escape 'a\"b')
    [ "${result}" = 'a\\\"b' ]
}

@test "newline becomes a short escape" {
    result=$(_knit_describe_json_escape $'line1\nline2')
    [ "${result}" = 'line1\nline2' ]
}

@test "tab and carriage return become short escapes" {
    result=$(_knit_describe_json_escape $'a\tb\rc')
    [ "${result}" = 'a\tb\rc' ]
}

@test "an other control character becomes a unicode escape" {
    result=$(_knit_describe_json_escape $'a\x01b')
    expected=$(printf 'a\\u0001b')
    [ "${result}" = "${expected}" ]
}

@test "empty string stays empty" {
    result=$(_knit_describe_json_escape "")
    [ "${result}" = "" ]
}

@test "an escaped string embeds into valid JSON" {
    local raw=$'tricky: "\\" \t and \n newline \x02'
    local escaped
    escaped=$(_knit_describe_json_escape "${raw}")
    # Round-trip through a JSON parser and confirm the original value survives.
    local back
    back=$(printf '"%s"' "${escaped}" \
        | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin))')
    [ "${back}" = "${raw}" ]
}

# ---------- _knit_describe_json_minify ----------

@test "minify removes whitespace outside strings" {
    result=$(_knit_describe_json_minify '{ "a" : 1 , "b" : [ 2 , 3 ] }')
    [ "${result}" = '{"a":1,"b":[2,3]}' ]
}

@test "minify removes newlines" {
    result=$(_knit_describe_json_minify $'{\n  "a": 1\n}')
    [ "${result}" = '{"a":1}' ]
}

@test "minify preserves spaces inside string values" {
    result=$(_knit_describe_json_minify '{ "k": "a b  c" }')
    [ "${result}" = '{"k":"a b  c"}' ]
}

@test "minify keeps an escaped quote inside a string" {
    result=$(_knit_describe_json_minify '{ "k": "a\"b c" }')
    [ "${result}" = '{"k":"a\"b c"}' ]
}

@test "minify keeps an escaped backslash inside a string" {
    result=$(_knit_describe_json_minify '{ "k": "a\\b c" }')
    [ "${result}" = '{"k":"a\\b c"}' ]
}

@test "minify output round-trips through a JSON parser" {
    local pretty='{
  "msg": "has: colon, comma and  spaces",
  "n": 1,
  "ok": true
}'
    local compact
    compact=$(_knit_describe_json_minify "${pretty}")
    printf '%s' "${compact}" | python3 -c 'import json,sys; json.load(sys.stdin)'
    [ "$(printf '%s' "${compact}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["msg"])')" \
        = "has: colon, comma and  spaces" ]
}
