#!/usr/bin/env bats

setup() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi

    source knit.sh

    # Override the sqlite executable and database path for testing
    __KNIT_SQLITE_EXE="sqlite3"
    __KNIT_DATABASE="$(mktemp --suffix=.db)"
}

teardown() {
    rm -f "${__KNIT_DATABASE}"
}

# ---------- _knit_db_create_table ----------

@test "create table creates the table in the database" {
    _knit_db_create_table "runs" "id:uuid" "duration:real"
    local result
    result=$(sqlite3 "${__KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='runs';")
    [ "$result" -eq 1 ]
}

@test "create table stores correct column names and types" {
    _knit_db_create_table "runs" "id:uuid" "count:integer" "label:string"
    local names types
    names=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f2)
    types=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f3)
    [ "$(echo "$names" | sed -n '1p')" = "id" ]
    [ "$(echo "$types" | sed -n '1p')" = "TEXT" ]
    [ "$(echo "$names" | sed -n '2p')" = "count" ]
    [ "$(echo "$types" | sed -n '2p')" = "INTEGER" ]
    [ "$(echo "$names" | sed -n '3p')" = "label" ]
    [ "$(echo "$types" | sed -n '3p')" = "TEXT" ]
}

@test "create table fails if table already exists" {
    _knit_db_create_table "runs" "id:uuid"
    run _knit_db_create_table "runs" "id:uuid"
    [ "$status" -ne 0 ]
}

@test "create table fails with zero columns" {
    run _knit_db_create_table "runs"
    [ "$status" -ne 0 ]
}

@test "create table fails with malformed column spec" {
    run _knit_db_create_table "runs" "id"
    [ "$status" -ne 0 ]
}

@test "create table fails with unknown column type" {
    run _knit_db_create_table "runs" "id:unknowntype"
    [ "$status" -ne 0 ]
}

@test "create table normalizes hyphen in column name" {
    _knit_db_create_table "runs" "my-col:integer"
    local name
    name=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f2)
    [ "$name" = "my_col" ]
}

# ---------- _knit_db_check_table ----------

@test "check table returns 1 for absent table" {
    run _knit_db_check_table "absent" "id:uuid"
    [ "$status" -eq 1 ]
}

@test "check table returns 0 for exact match" {
    _knit_db_create_table "runs" "id:uuid" "count:integer"
    run _knit_db_check_table "runs" "id:uuid" "count:integer"
    [ "$status" -eq 0 ]
}

@test "check table returns 2 when expected has fewer columns than actual" {
    _knit_db_create_table "runs" "id:uuid" "count:integer"
    run _knit_db_check_table "runs" "id:uuid"
    [ "$status" -eq 2 ]
}

@test "check table returns 2 when expected has more columns than actual" {
    _knit_db_create_table "runs" "id:uuid"
    run _knit_db_check_table "runs" "id:uuid" "count:integer"
    [ "$status" -eq 2 ]
}

@test "check table returns 2 on column name mismatch" {
    _knit_db_create_table "runs" "id:uuid" "count:integer"
    run _knit_db_check_table "runs" "id:uuid" "amount:integer"
    [ "$status" -eq 2 ]
}

@test "check table returns 2 on column type mismatch" {
    _knit_db_create_table "runs" "id:uuid" "count:integer"
    run _knit_db_check_table "runs" "id:uuid" "count:real"
    [ "$status" -eq 2 ]
}

@test "check table returns 2 on column order mismatch" {
    _knit_db_create_table "runs" "id:uuid" "count:integer"
    run _knit_db_check_table "runs" "count:integer" "id:uuid"
    [ "$status" -eq 2 ]
}

# ---------- _knit_db_migrate_table ----------

@test "migrate table fails when table does not exist" {
    run _knit_db_migrate_table "absent" "id:uuid"
    [ "$status" -ne 0 ]
}

@test "migrate table fails with zero columns" {
    _knit_db_create_table "runs" "id:uuid"
    run _knit_db_migrate_table "runs"
    [ "$status" -ne 0 ]
}

@test "migrate table fails when new column has no default" {
    _knit_db_create_table "runs" "id:uuid"
    run _knit_db_migrate_table "runs" "id:uuid" "count:integer"
    [ "$status" -ne 0 ]
}

@test "migrate table is a no-op when schema is unchanged" {
    _knit_db_create_table "runs" "id:uuid" "count:integer"
    sqlite3 "${__KNIT_DATABASE}" "INSERT INTO runs (id, count) VALUES ('550e8400-e29b-41d4-a716-446655440000', 1);"
    _knit_db_migrate_table "runs" "id:uuid" "count:integer"
    local rows
    rows=$(sqlite3 "${__KNIT_DATABASE}" "SELECT COUNT(*) FROM runs;")
    [ "$rows" -eq 1 ]
}

@test "migrate table adds a new column" {
    _knit_db_create_table "runs" "id:uuid"
    _knit_db_migrate_table "runs" "id:uuid" "label:string=unknown"
    local col
    col=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f2 | sed -n '2p')
    [ "$col" = "label" ]
}

@test "migrate table fills new column with default for existing rows" {
    _knit_db_create_table "runs" "id:uuid"
    sqlite3 "${__KNIT_DATABASE}" "INSERT INTO runs (id) VALUES ('550e8400-e29b-41d4-a716-446655440000');"
    _knit_db_migrate_table "runs" "id:uuid" "label:string=unknown"
    local val
    val=$(sqlite3 "${__KNIT_DATABASE}" "SELECT label FROM runs;")
    [ "$val" = "unknown" ]
}

@test "migrate table drops a column" {
    _knit_db_create_table "runs" "id:uuid" "count:integer"
    _knit_db_migrate_table "runs" "id:uuid"
    local ncols
    ncols=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('runs');" | wc -l)
    [ "$ncols" -eq 1 ]
}

@test "migrate table preserves existing row values" {
    _knit_db_create_table "runs" "id:uuid" "count:integer"
    sqlite3 "${__KNIT_DATABASE}" "INSERT INTO runs (id, count) VALUES ('550e8400-e29b-41d4-a716-446655440000', 42);"
    _knit_db_migrate_table "runs" "id:uuid" "count:integer" "label:string=x"
    local val
    val=$(sqlite3 "${__KNIT_DATABASE}" "SELECT count FROM runs;")
    [ "$val" -eq 42 ]
}

@test "migrate table changes column type" {
    _knit_db_create_table "runs" "id:uuid" "score:integer"
    _knit_db_migrate_table "runs" "id:uuid" "score:real"
    local col_type
    col_type=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f3 | sed -n '2p')
    [ "$col_type" = "REAL" ]
}

@test "migrate table handles multiple simultaneous changes" {
    _knit_db_create_table "runs" "id:uuid" "old_col:integer"
    sqlite3 "${__KNIT_DATABASE}" "INSERT INTO runs (id, old_col) VALUES ('550e8400-e29b-41d4-a716-446655440000', 7);"
    _knit_db_migrate_table "runs" "id:uuid" "new_col:string=hello"
    local names col_val
    names=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f2 | tr '\n' ',')
    col_val=$(sqlite3 "${__KNIT_DATABASE}" "SELECT new_col FROM runs;")
    [ "$names" = "id,new_col," ]
    [ "$col_val" = "hello" ]
}

@test "migrate table normalizes hyphen in column name" {
    _knit_db_create_table "runs" "id:uuid"
    _knit_db_migrate_table "runs" "id:uuid" "my-col:string=x"
    local col
    col=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f2 | sed -n '2p')
    [ "$col" = "my_col" ]
}

@test "migrate table default value with single quote is handled correctly" {
    _knit_db_create_table "runs" "id:uuid"
    sqlite3 "${__KNIT_DATABASE}" "INSERT INTO runs (id) VALUES ('550e8400-e29b-41d4-a716-446655440000');"
    _knit_db_migrate_table "runs" "id:uuid" "label:string=it's here"
    local val
    val=$(sqlite3 "${__KNIT_DATABASE}" "SELECT label FROM runs;")
    [ "$val" = "it's here" ]
}

# ---------- _knit_db_setup_table ----------

# Helper: register a minimal command with knit_with_table and call knit_done
__test_register_cmd() {
    local func="$1" cmd="$2" desc="$3"
    shift 3
    knit_register "${func}" "${cmd}" "${desc}"
    "$@"  # extra knit_with_* calls
    knit_with_table
    knit_done
}

@test "setup table creates table after command registration" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_table
    knit_done
    local result
    result=$(sqlite3 "${__KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='mycmd';")
    [ "$result" -eq 1 ]
}

@test "setup table creates id as the first column" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_table
    knit_done
    local first_col
    first_col=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | head -1)
    [ "$first_col" = "id" ]
}

@test "setup table includes required parameter as column" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_required "count:integer" "A count."
    knit_with_table
    knit_done
    local names
    names=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,count," ]
}

@test "setup table includes optional parameter as column" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_optional "label:string" "default" "A label."
    knit_with_table
    knit_done
    local names
    names=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,label," ]
}

@test "setup table includes flag as boolean column" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_flag "verbose" "Enable verbose output."
    knit_with_table
    knit_done
    local names types
    names=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | tr '\n' ',')
    types=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f3 | tr '\n' ',')
    [ "$names" = "id,verbose," ]
    [ "$types" = "TEXT,TEXT," ]
}

@test "setup table includes output as column" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_output "result:real" "0.0" "The result."
    knit_with_table
    knit_done
    local names
    names=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,result," ]
}

@test "setup table is a no-op when called again with same schema" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_required "count:integer" "A count."
    knit_with_table
    knit_done
    sqlite3 "${__KNIT_DATABASE}" "INSERT INTO mycmd (id, count) VALUES ('550e8400-e29b-41d4-a716-446655440000', 1);"
    # Call _knit_db_setup_table directly a second time — table must survive intact
    _knit_db_setup_table "mycmd" "mycmd"
    local rows
    rows=$(sqlite3 "${__KNIT_DATABASE}" "SELECT COUNT(*) FROM mycmd;")
    [ "$rows" -eq 1 ]
}

@test "setup table migrates when a new output is added" {
    # First registration: one required parameter
    knit_register knit_empty "mycmd" "A test command."
    knit_with_required "count:integer" "A count."
    knit_with_table
    knit_done
    sqlite3 "${__KNIT_DATABASE}" "INSERT INTO mycmd (id, count) VALUES ('550e8400-e29b-41d4-a716-446655440000', 7);"

    # Simulate a new output being added by calling _knit_db_setup_table with
    # a modified command state (add result to outputs set directly)
    _knit_set_add "_KNIT_CMD_mycmd_outputs" "result"
    eval "_KNIT_CMD_mycmd_3_result_type=real"
    eval "_KNIT_CMD_mycmd_3_result_default=0.0"
    _knit_db_setup_table "mycmd" "mycmd"

    local names
    names=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,count,result," ]
    local preserved
    preserved=$(sqlite3 "${__KNIT_DATABASE}" "SELECT count FROM mycmd;")
    [ "$preserved" -eq 7 ]
}
