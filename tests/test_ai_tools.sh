#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    KNIT_SCRIPT_NAME="my-exp.sh"
}

teardown() {
    knit_test_db_teardown
}

# ---------- _knit_ai_sql_is_readonly ----------

@test "sql guard accepts SELECT/WITH/EXPLAIN/PRAGMA (any case, leading ws)" {
    run _knit_ai_sql_is_readonly "SELECT * FROM runs";            [ "$status" -eq 0 ]
    run _knit_ai_sql_is_readonly "  select 1";                    [ "$status" -eq 0 ]
    run _knit_ai_sql_is_readonly "WITH t AS (SELECT 1) SELECT 2"; [ "$status" -eq 0 ]
    run _knit_ai_sql_is_readonly "EXPLAIN QUERY PLAN SELECT 1";   [ "$status" -eq 0 ]
    run _knit_ai_sql_is_readonly "pragma table_info(runs)";       [ "$status" -eq 0 ]
}

@test "sql guard rejects every write keyword" {
    local stmt
    for stmt in \
        "INSERT INTO runs VALUES (1)" \
        "UPDATE runs SET x=1" \
        "DELETE FROM runs" \
        "DROP TABLE runs" \
        "ALTER TABLE runs ADD c int" \
        "CREATE TABLE t (x int)" \
        "REPLACE INTO runs VALUES (1)" \
        "ATTACH DATABASE 'x' AS y"; do
        run _knit_ai_sql_is_readonly "${stmt}"
        [ "$status" -ne 0 ]
    done
}

@test "sql guard rejects a write piggy-backed on a SELECT" {
    run _knit_ai_sql_is_readonly "SELECT 1; DROP TABLE runs"
    [ "$status" -ne 0 ]
}

@test "sql guard rejects a non-read leading keyword" {
    run _knit_ai_sql_is_readonly "VACUUM"
    [ "$status" -ne 0 ]
    # "SELECTED" is a word starting with SELECT but is not the SELECT keyword.
    run _knit_ai_sql_is_readonly "SELECTED FROM x"
    [ "$status" -ne 0 ]
}

@test "sql guard does not misfire on a column named like a write keyword" {
    run _knit_ai_sql_is_readonly "SELECT created_at, updated_at FROM runs"
    [ "$status" -eq 0 ]
}

# ---------- _knit_ai_truncate ----------

@test "short tool results are not truncated" {
    run _knit_ai_truncate "hello"
    [ "$output" = "hello" ]
    [[ "$output" != *"(truncated)"* ]]
}

@test "long tool results are truncated with a marker" {
    local big
    big=$(printf 'x%.0s' $(seq 1 20000))
    run _knit_ai_truncate "${big}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(truncated)"* ]]
    # Bounded near the budget (8192), not the full 20000 characters.
    [ "${#output}" -lt 9000 ]
}

# ---------- _knit_ai_tools_schema ----------

@test "tools schema is a valid array of the five read-only function tools" {
    run _knit_ai_tools_schema
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq 'length')" = "5" ]
    [ "$(printf '%s' "$output" | jq -r '.[].function.name' | sort | tr '\n' ' ')" \
        = "knit_db_query knit_describe knit_help knit_job_output knit_metadata_show " ]
    # every tool is a function tool
    [ "$(printf '%s' "$output" | jq '[.[] | select(.type=="function")] | length')" = "5" ]
    # required args carried through
    [ "$(printf '%s' "$output" \
        | jq -r '.[] | select(.function.name=="knit_db_query") | .function.parameters.required[0]')" \
        = "sql" ]
    [ "$(printf '%s' "$output" \
        | jq -r '.[] | select(.function.name=="knit_job_output") | .function.parameters.properties.stream.enum | join(",")')" \
        = "stdout,stderr,script" ]
}

# ---------- _knit_ai_dispatch_tool ----------

@test "dispatch routes knit_describe with only/recursive args" {
    knit() { printf 'KNIT:%s\n' "$*"; }
    run _knit_ai_dispatch_tool knit_describe '{"only":"job","recursive":true}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"describe --format yaml --only job --recursive"* ]]
}

@test "dispatch omits describe --only/--recursive when not given" {
    knit() { printf 'KNIT:%s\n' "$*"; }
    run _knit_ai_dispatch_tool knit_describe '{}'
    [[ "$output" == *"describe --format yaml"* ]]
    [[ "$output" != *"--only"* ]]
    [[ "$output" != *"--recursive"* ]]
}

@test "dispatch routes knit_help, splitting a nested command name" {
    knit() { printf 'KNIT:%s\n' "$*"; }
    run _knit_ai_dispatch_tool knit_help '{"command":"job show stdout"}'
    [[ "$output" == *"job show stdout --help"* ]]
}

@test "dispatch routes knit_metadata_show" {
    knit() { printf 'KNIT:%s\n' "$*"; }
    run _knit_ai_dispatch_tool knit_metadata_show '{}'
    [[ "$output" == *"metadata show"* ]]
}

@test "dispatch routes knit_job_output to job show <stream>" {
    knit() { printf 'KNIT:%s\n' "$*"; }
    run _knit_ai_dispatch_tool knit_job_output '{"id":"uuid-1","stream":"stderr"}'
    [[ "$output" == *"job show stderr --id uuid-1"* ]]
}

@test "dispatch defaults the job_output stream to stdout" {
    knit() { printf 'KNIT:%s\n' "$*"; }
    run _knit_ai_dispatch_tool knit_job_output '{"id":"uuid-1"}'
    [[ "$output" == *"job show stdout --id uuid-1"* ]]
}

@test "dispatch rejects an unknown job_output stream" {
    knit() { printf 'KNIT:%s\n' "$*"; }
    run _knit_ai_dispatch_tool knit_job_output '{"id":"uuid-1","stream":"bogus"}'
    [[ "$output" == *"unknown stream"* ]]
    [[ "$output" != *"KNIT:"* ]]
}

@test "dispatch runs knit_db_query on the read path after the guard" {
    _knit_sqlite3() { printf 'SQLITE:%s\n' "$*"; }
    run _knit_ai_dispatch_tool knit_db_query '{"sql":"SELECT * FROM runs"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SQLITE:-header -column SELECT * FROM runs"* ]]
}

@test "dispatch rejects a write in knit_db_query without touching the DB" {
    _knit_sqlite3() { printf 'SHOULD-NOT-RUN\n'; }
    run _knit_ai_dispatch_tool knit_db_query '{"sql":"DROP TABLE runs"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rejected"* ]]
    [[ "$output" != *"SHOULD-NOT-RUN"* ]]
}

@test "dispatch returns an error for an unknown tool" {
    run _knit_ai_dispatch_tool no_such_tool '{}'
    [[ "$output" == *"unknown tool"* ]]
    [[ "$output" == *"no_such_tool"* ]]
}

@test "dispatch clears recording suppression before the handler runs" {
    # Observe the suppression state from inside a stubbed handler.
    _knit_ai_tool_metadata_show() {
        printf 'SUP=[%s] DIS=[%s]' \
            "${_KNIT_RECORDING_SUPPRESSED}" "${KNIT_DISABLE_RECORDING:-UNSET}"
    }
    _KNIT_RECORDING_SUPPRESSED="1"
    export KNIT_DISABLE_RECORDING="true"

    run _knit_ai_dispatch_tool knit_metadata_show '{}'
    [[ "$output" == *"SUP=[] DIS=[UNSET]"* ]]
}
