#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

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

@test "query loop --query-only prints the SQL and its language and does not run it" {
    _stub_curl_seq "$(_sql_resp 'DROP TABLE t')"
    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "drop it" "sys" 3 \
        false true csv false "" auto
    [ "$status" -eq 0 ]
    # The query lands on stdout; the language line on stderr (both in $output).
    [[ "$output" == *"DROP TABLE t"* ]]
    [[ "$output" == *"language: sql"* ]]
    # Only one call; the (write) statement was never executed.
    [ "$(cat "${KNIT_T_SEQ}/n")" = "1" ]
    run _knit_sqlite3 "SELECT count(*) FROM t"
    [ "$output" = "2" ]
}

@test "query loop --query-only keeps the query alone on stdout" {
    _stub_curl_seq "$(_sql_resp 'SELECT name FROM t')"
    run --separate-stderr _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" \
        "names?" "sys" 3 false true csv false "" auto
    [ "$status" -eq 0 ]
    [ "$output" = "SELECT name FROM t" ]
    [[ "$stderr" == *"language: sql"* ]]
}

@test "query loop --verbose streams the language, generated query and sqlite errors to stderr" {
    _stub_curl_seq \
        "$(_sql_resp 'SELECT nope FROM t')" \
        "$(_sql_resp 'SELECT name FROM t')"
    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "names?" "sys" 3 \
        true false csv false "" auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"language: sql"* ]]
    [[ "$output" == *"generated query"* ]]
    [[ "$output" == *"sqlite error"* ]]
}

# ---------- _knit_ai_query_loop: Cypher branch (no lens) ----------
#
# With no lens (a direct 12-arg call), the Cypher path builds the flat schema from
# the current database, transpiles with knit-cypher-to-sql, and runs the returned
# SQL on the read path via _knit_sqlite3. The transpiler is stubbed to record its
# argv and emit SQL; the real _knit_sqlite3 runs that SQL against a seeded DB.

@test "query loop routes Cypher through the transpiler and runs the returned SQL" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j1'),('j2');"
    local argfile="${BATS_TEST_TMPDIR}/cts-args"
    _knit_cypher_to_sql() {
        printf '%s\n' "$*" > "${argfile}"
        printf 'SELECT id FROM jobs ORDER BY id\n'
    }
    _stub_curl_seq "$(_sql_resp 'MATCH (j:jobs) RETURN j.id')"

    # no_header=true so the two rows are the only output lines.
    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "graph?" "sys" 3 \
        false false list true "" auto
    [ "$status" -eq 0 ]
    # The result of running the transpiled SQL over the read path.
    [ "${lines[0]}" = "j1" ]
    [ "${lines[1]}" = "j2" ]
    # The transpiler received the live name<->table map and the Cypher.
    [[ "$(cat "${argfile}")" == *"--names "* ]]
    [[ "$(cat "${argfile}")" == *"MATCH (j:jobs) RETURN j.id"* ]]
}

@test "query loop feeds a transpile error back and the second attempt succeeds" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j1');"
    # Fail transpiling the first (bad) query; succeed on the corrected one.
    _knit_cypher_to_sql() {
        if [[ "${!#}" == *bad* ]]; then
            printf 'syntax error near "bad"\n' >&2
            return 1
        fi
        printf 'SELECT id FROM jobs ORDER BY id\n'
    }
    _stub_curl_seq \
        "$(_sql_resp 'MATCH bad RETURN x')" \
        "$(_sql_resp 'MATCH (j:jobs) RETURN j.id')"

    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "graph?" "sys" 3 \
        false false list false "" auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"j1"* ]]
    # Exactly two provider calls; the second carried the transpile error back.
    [ "$(cat "${KNIT_T_SEQ}/n")" = "2" ]
    local body2; body2=$(cat "${KNIT_T_SEQ}/body_2")
    [[ "$(printf '%s' "${body2}" | jq -r '.messages[-1].content')" == *"Translating that Cypher"* ]]
    [[ "$(printf '%s' "${body2}" | jq -r '.messages[-1].content')" == *"syntax error"* ]]
}

@test "query loop fatals after Cypher hits the iteration cap" {
    knit_test_require_sqlite
    _stub_curl_seq \
        "$(_sql_resp 'MATCH bad RETURN x')" \
        "$(_sql_resp 'MATCH worse RETURN y')"
    _knit_cypher_to_sql() { printf 'boom\n' >&2; return 1; }

    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "graph?" "sys" 2 \
        false false list false "" auto
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not produce a working query"* ]]
    [ "$(cat "${KNIT_T_SEQ}/n")" = "2" ]
}

@test "query loop --query-only prints a Cypher query and its language without transpiling" {
    _stub_curl_seq "$(_sql_resp 'MATCH (n) RETURN n')"
    # Any call to the transpiler is a failure for this test.
    _knit_cypher_to_sql() { printf 'SHOULD-NOT-RUN\n'; return 0; }

    run --separate-stderr _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" \
        "graph?" "sys" 3 false true list false "" auto
    [ "$status" -eq 0 ]
    [ "$output" = "MATCH (n) RETURN n" ]
    [[ "$stderr" == *"language: cypher"* ]]
    [ "$(cat "${KNIT_T_SEQ}/n")" = "1" ]
}

@test "query loop honors a pinned --lang cypher and routes to the transpiler" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j1');"
    # The reply looks like SQL, but the pinned language forces the Cypher path,
    # so the statement is sent to the transpiler (not run as SQL directly).
    local argfile="${BATS_TEST_TMPDIR}/cts-args"
    _knit_cypher_to_sql() {
        printf '%s\n' "$*" > "${argfile}"
        printf 'SELECT id FROM jobs\n'
    }
    _stub_curl_seq "$(_sql_resp 'SELECT 1')"

    run _knit_ai_query_loop "http://h/v1" "sk" "gpt-x" "graph?" "sys" 3 \
        false false list false "" cypher
    [ "$status" -eq 0 ]
    [[ "$output" == *"j1"* ]]
    [[ "$(cat "${argfile}")" == *"SELECT 1"* ]]
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

@test "ai query --query-only prints the query and language via the dispatcher" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _stub_curl_seq "$(_sql_resp 'SELECT name FROM t')"

    run knit ai query --question "list names" --query-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"SELECT name FROM t"* ]]
    [[ "$output" == *"language: sql"* ]]
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

# ---------- --extra (cross-platform lens, SQL path) ----------

# Label the current database as platform "alpha" and fabricate a second
# single-platform database "beta" beside it (a distinct row in its own t table),
# so a lens over both spans two platforms. Only the copy is touched.
_seed_two_platforms_ai() {
    _knit_sqlite3_write \
        "INSERT INTO metadata VALUES('__platform__','alpha'),('__arch__','x86_64');"
    BETA_DB="${BATS_TEST_TMPDIR}/beta.db"
    "${_KNIT_SQLITE_EXE}" "${BETA_DB}" "
        CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO metadata VALUES('__platform__','beta'),('__arch__','aarch64');
        CREATE TABLE t(name TEXT, n INT);
        INSERT INTO t VALUES('carol', 3);"
}

@test "ai query --extra queries the platforms view spanning both databases" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _seed_two_platforms_ai
    _stub_curl_seq "$(_sql_resp 'SELECT id FROM platforms ORDER BY id')"

    run knit ai query --question "which platforms" --extra "${BETA_DB}" --format csv
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
}

@test "ai query --extra unions a command table across both databases" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _seed_two_platforms_ai
    _stub_curl_seq "$(_sql_resp 'SELECT name FROM t ORDER BY name')"

    # The lens unions t across alpha (alice, bob) and beta (carol).
    run knit ai query --question "all names" --extra "${BETA_DB}" --format csv
    [ "$status" -eq 0 ]
    [[ "$output" == *"alice"* ]]
    [[ "$output" == *"bob"* ]]
    [[ "$output" == *"carol"* ]]
}

@test "ai query without --extra does not reach an extra database" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _seed_two_platforms_ai
    _stub_curl_seq "$(_sql_resp 'SELECT count(*) FROM t')"

    # A single-database lens sees only the current database's two rows.
    run knit ai query --question "how many" --extra "" --format csv
    [ "$status" -eq 0 ]
    [[ "$output" == *"2"* ]]
    [[ "$output" != *"3"* ]]
}

# ---------- --extra (cross-platform lens, Cypher path) ----------

# Point _KNIT_CYPHER_TO_SQL_EXE at the in-tree build, or skip when it is absent
# (the live path is also covered by integration).
_require_cypher_to_sql() {
    local cts="${BATS_TEST_DIRNAME}/../knit-cypher-to-sql/build/src/knit-cypher-to-sql"
    [[ -x "${cts}" ]] || skip "knit-cypher-to-sql binary not built"
    _KNIT_CYPHER_TO_SQL_EXE="${cts}"
}

@test "ai query --lang cypher --extra transpiles and runs over the lens" {
    _require_cypher_to_sql
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _seed_two_platforms_ai
    # (p:platform) resolves to the synthesized platforms view across both dbs.
    _stub_curl_seq "$(_sql_resp 'MATCH (p:platform) RETURN p.id')"

    run knit ai query --question "which platforms" --lang cypher \
        --extra "${BETA_DB}" --format csv
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
}

@test "ai query --lang cypher feeds a transpile error back and recovers" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _seed_two_platforms_ai
    # Stub the transpiler: fail on the "bad" Cypher, transpile the good one to SQL.
    _knit_cypher_to_sql() {
        local cy="${!#}"
        if [[ "${cy}" == *bad* ]]; then
            printf 'cypher parse error near "bad"\n' >&2
            return 1
        fi
        printf 'SELECT id FROM platforms ORDER BY id\n'
    }
    _stub_curl_seq \
        "$(_sql_resp 'MATCH bad RETURN x')" \
        "$(_sql_resp 'MATCH (p:platform) RETURN p.id')"

    run knit ai query --question "which platforms" --lang cypher \
        --extra "${BETA_DB}" --format csv
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
    # Two provider calls; the second carried the transpile error back.
    [ "$(cat "${KNIT_T_SEQ}/n")" = "2" ]
    local body2; body2=$(cat "${KNIT_T_SEQ}/body_2")
    [[ "$(printf '%s' "${body2}" | jq -r '.messages[-1].content')" == *"Translating that Cypher"* ]]
    [[ "$(printf '%s' "${body2}" | jq -r '.messages[-1].content')" == *"parse error"* ]]
}

@test "ai query --lang cypher feeds an execution error back and recovers" {
    _knit_ai_store_config KNIT_T_KEY "" "" "http://host/v1" "gpt-x" "true"
    export KNIT_T_KEY="sk-secret"
    _seed_two_platforms_ai
    # Stub the transpiler: the first Cypher transpiles to SQL that fails over the
    # lens (no such view); the second transpiles to valid SQL.
    _knit_cypher_to_sql() {
        local cy="${!#}"
        if [[ "${cy}" == *first* ]]; then
            printf 'SELECT id FROM no_such_view\n'
            return 0
        fi
        printf 'SELECT id FROM platforms ORDER BY id\n'
    }
    _stub_curl_seq \
        "$(_sql_resp 'MATCH (first) RETURN x')" \
        "$(_sql_resp 'MATCH (p:platform) RETURN p.id')"

    run knit ai query --question "which platforms" --lang cypher \
        --extra "${BETA_DB}" --format csv
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
    # Two provider calls; the second carried the sqlite execution error back.
    [ "$(cat "${KNIT_T_SEQ}/n")" = "2" ]
    local body2; body2=$(cat "${KNIT_T_SEQ}/body_2")
    [[ "$(printf '%s' "${body2}" | jq -r '.messages[-1].content')" == *"Running the SQL translated"* ]]
    [[ "$(printf '%s' "${body2}" | jq -r '.messages[-1].content')" == *"no_such_view"* ]]
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

@test "query system prompt (auto) seeds both halves, the name map and edge model" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")
    run _knit_ai_query_system_prompt auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"SINGLE fenced code block"* ]]
    [[ "$output" == *"CREATE TABLE t"* ]]   # the SQL half's seeded schema
    [[ "$output" == *"jobs=submit"* ]]      # the live name<->table map
    [[ "$output" == *"used_by"* ]]          # the edge model
    [[ "$output" == *"Cypher rules"* ]]
    [[ "$output" == *"SQL rules"* ]]
    [[ "$output" == *"- ai query:"* ]]      # the compact describe summary
}

@test "query system prompt --lang sql emits only the SQL half" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")
    run _knit_ai_query_system_prompt sql
    [ "$status" -eq 0 ]
    [[ "$output" == *'tagged `sql`'* ]]
    [[ "$output" == *"CREATE TABLE t"* ]]   # schema present
    [[ "$output" == *"SQL rules"* ]]
    [[ "$output" != *"Cypher rules"* ]]     # no Cypher half
    [[ "$output" != *"jobs=submit"* ]]      # no name map
}

@test "query system prompt --lang cypher emits only the Cypher half" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")
    run _knit_ai_query_system_prompt cypher
    [ "$status" -eq 0 ]
    [[ "$output" == *'tagged `cypher`'* ]]
    [[ "$output" == *"Cypher rules"* ]]
    [[ "$output" == *"jobs=submit"* ]]      # the name map present
    [[ "$output" == *"used_by"* ]]          # the edge model present
    [[ "$output" != *"SQL rules"* ]]        # no SQL half
    [[ "$output" != *"Database schema:"* ]] # no schema block
}

@test "query system prompt adds the cross-platform note only with --extra" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")

    # has_extra=true: the SQL half describes the lens and the platforms view.
    run _knit_ai_query_system_prompt sql true
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cross-platform querying"* ]]
    [[ "$output" == *'"platforms" view'* ]]

    # Default (no --extra): no cross-platform note.
    run _knit_ai_query_system_prompt sql
    [ "$status" -eq 0 ]
    [[ "$output" != *"Cross-platform querying"* ]]
}

@test "query system prompt cypher half describes the platform node only with --extra" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")

    # has_extra=true: the Cypher half describes the platform node and executed edge.
    run _knit_ai_query_system_prompt cypher true
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cross-platform querying"* ]]
    [[ "$output" == *"executed"* ]]
    [[ "$output" == *"(p:platform)"* ]]

    # Default (no --extra): no cross-platform note.
    run _knit_ai_query_system_prompt cypher
    [ "$status" -eq 0 ]
    [[ "$output" != *"Cross-platform querying"* ]]
}
