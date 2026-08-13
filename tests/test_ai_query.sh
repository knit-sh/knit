#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    KNIT_SCRIPT_NAME="my-exp.sh"
    _knit_create_metadata_table

    # A small real table for the query loop to run against.
    _knit_sqlite3_write "CREATE TABLE t(name TEXT, n INT);"
    _knit_sqlite3_write "INSERT INTO t VALUES('alice', 2), ('bob', 1);"
}

teardown() {
    knit_test_db_teardown
}

# Stub curl to return a canned response per call, in order, and capture each
# request body to a numbered file so a later turn's payload can be inspected.
_stub_curl_seq() {
    export KNIT_T_SEQ="${BATS_TEST_TMPDIR}/seq"
    rm -rf "${KNIT_T_SEQ}"; mkdir -p "${KNIT_T_SEQ}"
    local i=1 r
    for r in "$@"; do
        printf '%s' "${r}" > "${KNIT_T_SEQ}/resp_${i}"
        (( i++ ))
    done
    printf '0' > "${KNIT_T_SEQ}/n"
    curl() {
        local cfg="" out=""
        while (( $# )); do
            case "$1" in
                -K) cfg="$2"; shift 2 ;;
                -o) out="$2"; shift 2 ;;
                *)  shift ;;
            esac
        done
        local n
        n=$(<"${KNIT_T_SEQ}/n"); n=$(( n + 1 ))
        printf '%s' "${n}" > "${KNIT_T_SEQ}/n"
        local bf
        bf=$(sed -n 's/^data-binary = "@\(.*\)"$/\1/p' "${cfg}")
        [[ -n "${bf}" ]] && cp "${bf}" "${KNIT_T_SEQ}/body_${n}"
        # Mirror real curl -o/-w: body to the file, status code to stdout.
        if [[ -n "${out}" ]]; then
            cat "${KNIT_T_SEQ}/resp_${n}" > "${out}"
            printf '200'
        else
            cat "${KNIT_T_SEQ}/resp_${n}"
        fi
    }
}

# Shorthand: an assistant reply whose content is the given SQL text.
_sql_resp() {
    _knit_jq -n --arg sql "$1" '{choices:[{message:{role:"assistant",content:$sql}}]}'
}

# ---------- _knit_ai_query_mode_args ----------

@test "mode args map the format, headers, and separator" {
    local -a args
    _knit_ai_query_mode_args args "box" "false" ""
    [ "${args[*]}" = "-cmd .mode box -cmd .headers on" ]

    _knit_ai_query_mode_args args "csv" "true" ";"
    [ "${args[*]}" = "-cmd .mode csv -cmd .headers off -cmd .separator ;" ]
}

# ---------- _knit_ai_extract_query ----------

@test "extract_query returns a bare statement unchanged (trimmed) as sql" {
    local lang query
    _knit_ai_extract_query lang query "  SELECT 1  "
    [ "$lang" = "sql" ]
    [ "$query" = "SELECT 1" ]
}

@test "extract_query reads the sql fence info string" {
    local lang query
    _knit_ai_extract_query lang query $'```sql\nSELECT name FROM t\n```'
    [ "$lang" = "sql" ]
    [ "$query" = "SELECT name FROM t" ]
}

@test "extract_query reads the cypher fence info string (case-insensitive)" {
    local lang query
    _knit_ai_extract_query lang query $'```Cypher\nMATCH (n) RETURN n\n```'
    [ "$lang" = "cypher" ]
    [ "$query" = "MATCH (n) RETURN n" ]
}

@test "extract_query infers cypher from a leading keyword in a bare fence" {
    local lang query
    _knit_ai_extract_query lang query $'```\nMATCH (n) RETURN n\n```'
    [ "$lang" = "cypher" ]
    [ "$query" = "MATCH (n) RETURN n" ]
}

@test "extract_query infers sql from a leading keyword in a bare fence" {
    local lang query
    _knit_ai_extract_query lang query $'```\nWITH x AS (SELECT 1) SELECT * FROM x\n```'
    [ "$lang" = "sql" ]
    [ "$query" = "WITH x AS (SELECT 1) SELECT * FROM x" ]
}

@test "extract_query drops an unknown fence tag and infers from the keyword" {
    local lang query
    _knit_ai_extract_query lang query $'```postgres\nMATCH (n) RETURN n\n```'
    [ "$lang" = "cypher" ]
    [ "$query" = "MATCH (n) RETURN n" ]
}

@test "extract_query falls back to sql for an ambiguous statement" {
    local lang query
    _knit_ai_extract_query lang query "SHOW TABLES"
    [ "$lang" = "sql" ]
    [ "$query" = "SHOW TABLES" ]
}

# ---------- _knit_ai_query_loop ----------

@test "query loop runs generated SQL and prints it in the chosen format" {
    _stub_curl_seq "$(_sql_resp 'SELECT name FROM t ORDER BY n')"
    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "names?" "sys" 3 \
        false false csv false "" auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"name"* ]]   # header present by default
    [[ "$output" == *"bob"* ]]
    [[ "$output" == *"alice"* ]]
}

@test "query loop rejects a write statement without running it" {
    _stub_curl_seq "$(_sql_resp 'DROP TABLE t')"
    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "drop it" "sys" 1 \
        false false csv false "" auto
    [ "$status" -ne 0 ]
    # The table still exists: the write never reached the database.
    run _knit_sqlite3 "SELECT count(*) FROM t"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "query loop feeds a sqlite error back and the second attempt succeeds" {
    _stub_curl_seq \
        "$(_sql_resp 'SELECT nope FROM t')" \
        "$(_sql_resp 'SELECT name FROM t ORDER BY n')"
    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "names?" "sys" 3 \
        false false csv false "" auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"alice"* ]]
    # Exactly two provider calls; the second carried the sqlite error back.
    [ "$(cat "${KNIT_T_SEQ}/n")" = "2" ]
    local body2; body2=$(cat "${KNIT_T_SEQ}/body_2")
    [[ "$(printf '%s' "${body2}" | jq -r '.messages[-1].content')" == *"no such column"* ]]
}

@test "query loop fatals after hitting the iteration cap" {
    _stub_curl_seq \
        "$(_sql_resp 'SELECT nope FROM t')" \
        "$(_sql_resp 'SELECT still_nope FROM t')"
    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "names?" "sys" 2 \
        false false csv false "" auto
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not produce a working query"* ]]
    [ "$(cat "${KNIT_T_SEQ}/n")" = "2" ]
}

@test "query loop --sql-only prints the SQL and does not run it" {
    _stub_curl_seq "$(_sql_resp 'DROP TABLE t')"
    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "drop it" "sys" 3 \
        false true csv false "" auto
    [ "$status" -eq 0 ]
    [ "$output" = "DROP TABLE t" ]
    # Only one call; the (write) statement was never executed.
    [ "$(cat "${KNIT_T_SEQ}/n")" = "1" ]
    run _knit_sqlite3 "SELECT count(*) FROM t"
    [ "$output" = "2" ]
}

@test "query loop --verbose streams generated SQL and sqlite errors to stderr" {
    _stub_curl_seq \
        "$(_sql_resp 'SELECT nope FROM t')" \
        "$(_sql_resp 'SELECT name FROM t')"
    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "names?" "sys" 3 \
        true false csv false "" auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"generated SQL"* ]]
    [[ "$output" == *"sqlite error"* ]]
}

# ---------- _knit_ai_query_loop: Cypher branch ----------

@test "query loop routes Cypher to knit-graph with the name map and output flags" {
    _stub_curl_seq "$(_sql_resp 'MATCH (n) RETURN n')"
    # Capture the exact argv knit-graph is called with.
    _knit_knit_graph() { printf 'KG:%s\n' "$*"; }

    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "graph?" "sys" 3 \
        false false csv false "" auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"--names "* ]]        # live name<->table map passed
    [[ "$output" == *"-csv"* ]]            # format mapped to knit-graph flag
    [[ "$output" == *"-header"* ]]         # headers on by default
    [[ "$output" == *"MATCH (n) RETURN n"* ]]
}

@test "query loop maps --no-header to knit-graph -noheader for Cypher" {
    _stub_curl_seq "$(_sql_resp 'MATCH (n) RETURN n')"
    _knit_knit_graph() { printf 'KG:%s\n' "$*"; }

    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "graph?" "sys" 3 \
        false false csv true "" auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"-noheader"* ]]
    [[ "$output" != *"-header "* ]]
}

@test "query loop feeds a knit-graph error back and the second attempt succeeds" {
    _stub_curl_seq \
        "$(_sql_resp 'MATCH bad RETURN x')" \
        "$(_sql_resp 'MATCH (n) RETURN n')"
    # Fail the first (bad) query; succeed on the corrected one.
    _knit_knit_graph() {
        if [[ "$*" == *bad* ]]; then
            printf 'syntax error near "bad"\n' >&2
            return 1
        fi
        printf 'GRAPH-RESULT\n'
    }

    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "graph?" "sys" 3 \
        false false csv false "" auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"GRAPH-RESULT"* ]]
    # Exactly two provider calls; the second carried knit-graph's error back.
    [ "$(cat "${KNIT_T_SEQ}/n")" = "2" ]
    local body2; body2=$(cat "${KNIT_T_SEQ}/body_2")
    [[ "$(printf '%s' "${body2}" | jq -r '.messages[-1].content')" == *"syntax error"* ]]
}

@test "query loop fatals after Cypher hits the iteration cap" {
    _stub_curl_seq \
        "$(_sql_resp 'MATCH bad RETURN x')" \
        "$(_sql_resp 'MATCH worse RETURN y')"
    _knit_knit_graph() { printf 'boom\n' >&2; return 1; }

    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "graph?" "sys" 2 \
        false false csv false "" auto
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not produce a working query"* ]]
    [ "$(cat "${KNIT_T_SEQ}/n")" = "2" ]
}

@test "query loop --sql-only prints a Cypher query without running knit-graph" {
    _stub_curl_seq "$(_sql_resp 'MATCH (n) RETURN n')"
    # Any call to the backend is a failure for this test.
    _knit_knit_graph() { printf 'SHOULD-NOT-RUN\n'; return 0; }

    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "graph?" "sys" 3 \
        false true csv false "" auto
    [ "$status" -eq 0 ]
    [ "$output" = "MATCH (n) RETURN n" ]
    [ "$(cat "${KNIT_T_SEQ}/n")" = "1" ]
}

@test "query loop honors a pinned --lang cypher and routes to knit-graph" {
    # The reply looks like SQL, but the pinned language forces the Cypher backend.
    _stub_curl_seq "$(_sql_resp 'SELECT 1')"
    _knit_knit_graph() { printf 'KG:%s\n' "$*"; }

    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "graph?" "sys" 3 \
        false false csv false "" cypher
    [ "$status" -eq 0 ]
    [[ "$output" == *"KG:"* ]]
    [[ "$output" == *"SELECT 1"* ]]
}

# ---------- ai query (end to end via the dispatcher, stubbed curl) ----------

@test "ai query resolves config, runs the loop, and prints the result" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _stub_curl_seq "$(_sql_resp 'SELECT name FROM t ORDER BY n')"

    run knit ai query --question "list names" --format csv
    [ "$status" -eq 0 ]
    [[ "$output" == *"bob"* ]]
    [[ "$output" == *"alice"* ]]
}

@test "ai query --sql-only prints SQL via the dispatcher" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _stub_curl_seq "$(_sql_resp 'SELECT name FROM t')"

    run knit ai query --question "list names" --sql-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"SELECT name FROM t"* ]]
}

@test "ai query fatals cleanly when the provider is not configured" {
    run knit ai query --question "list names"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not configured"* ]]
}

@test "ai query rejects an invalid --format value" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    run knit ai query --question "x" --format bogus
    [ "$status" -ne 0 ]
}

@test "ai query --format accepts a query_format-only value (tabs)" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _stub_curl_seq "$(_sql_resp 'SELECT name FROM t ORDER BY n')"

    # "tabs" is in query_format but was not in the retired sqlite_format enum.
    run knit ai query --question "list names" --format tabs
    [ "$status" -eq 0 ]
    [[ "$output" == *"alice"* ]]
    [[ "$output" == *"bob"* ]]
}

@test "ai query --format defaults to box" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _stub_curl_seq "$(_sql_resp 'SELECT name FROM t ORDER BY n')"

    # The box mode draws a Unicode-boxed table around the result.
    run knit ai query --question "list names"
    [ "$status" -eq 0 ]
    [[ "$output" == *"│"* ]]
    [[ "$output" == *"alice"* ]]
}

# ---------- --lang ----------

@test "ai query forwards --lang to the query loop" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    # Capture the loop's pinned-language argument (12th positional).
    _knit_ai_query_loop() { printf 'LANG=%s\n' "${12}"; }

    run knit ai query --question "x" --lang cypher
    [ "$status" -eq 0 ]
    [[ "$output" == *"LANG=cypher"* ]]

    run knit ai query --question "x" --lang sql
    [ "$status" -eq 0 ]
    [[ "$output" == *"LANG=sql"* ]]
}

@test "ai query --lang defaults to auto" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _knit_ai_query_loop() { printf 'LANG=%s\n' "${12}"; }

    run knit ai query --question "x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"LANG=auto"* ]]
}

@test "ai query rejects an invalid --lang value" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    run knit ai query --question "x" --lang bogus
    [ "$status" -ne 0 ]
}

# ---------- system prompt ----------

@test "query system prompt seeds the schema and a one-statement instruction" {
    run _knit_ai_query_system_prompt
    [ "$status" -eq 0 ]
    [[ "$output" == *"SINGLE SQL statement"* ]]
    [[ "$output" == *"CREATE TABLE t"* ]]   # the seeded schema
    [[ "$output" == *"- ai query:"* ]]      # the compact describe summary
}
