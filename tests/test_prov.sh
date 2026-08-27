#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- _knit_prov_create_table ----------

@test "create table makes the __provenance__ table" {
    _knit_prov_create_table
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='__provenance__';")
    [ "$n" -eq 1 ]
}

@test "create table defines the schema columns in order" {
    _knit_prov_create_table
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" \
        "PRAGMA table_info('__provenance__');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "source_id,source_name,target_id,target_name,edge_type,start_time,end_time,alias," ]
}

@test "create table gives the timestamp columns REAL affinity" {
    _knit_prov_create_table
    local start_type end_type
    start_type=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT type FROM pragma_table_info('__provenance__') WHERE name='start_time';")
    end_type=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT type FROM pragma_table_info('__provenance__') WHERE name='end_time';")
    [ "$start_type" = "REAL" ]
    [ "$end_type" = "REAL" ]
}

@test "create table is idempotent" {
    _knit_prov_create_table
    _knit_prov_create_table
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='__provenance__';")
    [ "$n" -eq 1 ]
}

# ---------- _knit_prov_record_edge ----------

@test "record edge inserts a call edge with all fields" {
    _knit_prov_create_table
    _knit_prov_record_edge "pid" "submit:mc" "cid" "run" "call" "10.5" "12.25"

    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM __provenance__;")" -eq 1 ]
    local row
    row=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT source_id,source_name,target_id,target_name,edge_type,start_time,end_time FROM __provenance__;")
    [ "$row" = "pid|submit:mc|cid|run|call|10.5|12.25" ]
}

@test "record edge leaves alias NULL when unset" {
    _knit_prov_create_table
    _knit_prov_record_edge "pid" "submit:mc" "cid" "run" "call" "10.5" "12.25"

    local nulls
    nulls=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM __provenance__ WHERE alias IS NULL;")
    [ "$nulls" -eq 1 ]
}

@test "record edge stores a call-site alias" {
    _knit_prov_create_table
    _knit_prov_record_edge "pid" "montecarlo" "cid" "runs" "call" "1" "2" "fast"

    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT alias FROM __provenance__;")" = "fast" ]
}

@test "record edge stores empty timestamps as NULL (used_by edge)" {
    _knit_prov_create_table
    _knit_prov_record_edge "sid" "setup:libs" "cid" "submit:mc" "used_by" "" ""

    local nulls
    nulls=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM __provenance__ WHERE start_time IS NULL AND end_time IS NULL;")
    [ "$nulls" -eq 1 ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT edge_type FROM __provenance__;")" = "used_by" ]
}

@test "record edge records an empty parent for a root invocation" {
    _knit_prov_create_table
    _knit_prov_record_edge "" "" "cid" "top" "call" "1" "2"

    local roots
    roots=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM __provenance__ WHERE source_id='' AND source_name='';")
    [ "$roots" -eq 1 ]
}

@test "record edge escapes single quotes in fields" {
    _knit_prov_create_table
    _knit_prov_record_edge "pid" "a'b" "cid" "c'd" "call" "1" "2"

    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT source_name FROM __provenance__;")" = "a'b" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT target_name FROM __provenance__;")" = "c'd" ]
}

# ---------- _knit_prov_edge_sql ----------

@test "edge insert sql renders empty timestamps and alias as bare NULL" {
    local sql
    sql=$(_knit_prov_edge_sql "p" "pn" "c" "cn" "used_by" "" "")
    [[ "$sql" == *"'used_by', NULL, NULL, NULL);" ]]
}

@test "edge insert sql quotes non-empty timestamps" {
    local sql
    sql=$(_knit_prov_edge_sql "p" "pn" "c" "cn" "call" "3.5" "4.5")
    [[ "$sql" == *"'call', '3.5', '4.5', NULL);" ]]
}

@test "edge insert sql quotes a non-empty alias" {
    local sql
    sql=$(_knit_prov_edge_sql "p" "pn" "c" "cn" "call" "3.5" "4.5" "fast")
    [[ "$sql" == *"'call', '3.5', '4.5', 'fast');" ]]
}

@test "edge insert sql lists the alias column" {
    local sql
    sql=$(_knit_prov_edge_sql "p" "pn" "c" "cn" "call" "" "")
    [[ "$sql" == *"start_time, end_time, alias) VALUES"* ]]
}

# ---------- _knit_produced_edge_sql ----------

@test "produced edge sql targets the artifacts node with NULL times and alias" {
    local sql
    sql=$(_knit_produced_edge_sql "pid" "submit:bundle" "aid")
    [[ "$sql" == *"'pid', 'submit:bundle', 'aid', 'artifacts', 'produced', NULL, NULL, NULL);" ]]
}

@test "produced edge sql inserts a produced edge into the provenance table" {
    _knit_prov_create_table
    _knit_sqlite3_write "$(_knit_produced_edge_sql "pid" "run:julia" "aid")"
    local row
    row=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT source_id,source_name,target_id,target_name,edge_type FROM __provenance__;")
    [ "$row" = "pid|run:julia|aid|artifacts|produced" ]
}
