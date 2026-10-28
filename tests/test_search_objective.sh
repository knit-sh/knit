#!/usr/bin/env bats
#
# Tests for knit_search_read_objective: resolve a trial's objective row by
# walking provenance "call" edges from the launch child id, then read the column.

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_require_sqlite
    knit_test_db_setup
    # A dispatcher row (the launch id), a descendant body row (holds the
    # objective), and a "call" edge linking them, mirroring submit/run.
    _knit_sqlite3 "CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT);"
    _knit_sqlite3 "CREATE TABLE body (id TEXT PRIMARY KEY, val_loss REAL);"
    _knit_sqlite3 "CREATE TABLE ${_KNIT_PROV_TABLE} (source_id TEXT, target_id TEXT, edge_type TEXT);"
    _knit_sqlite3 "INSERT INTO jobs VALUES ('job-1','completed');"
    _knit_sqlite3 "INSERT INTO ${_KNIT_PROV_TABLE} (source_id,target_id,edge_type) VALUES ('job-1','body-1','call');"
}

teardown() {
    knit_test_db_teardown
}

@test "reads the objective from a descendant row one call edge away" {
    _knit_sqlite3 "INSERT INTO body (id, val_loss) VALUES ('body-1', 0.25);"
    local v
    knit_search_read_objective v "job-1" "body" "val_loss"
    [ "$v" = "0.25" ]
}

@test "reads an objective recorded directly in the launch id's own table" {
    local v
    knit_search_read_objective v "job-1" "jobs" "state"
    [ "$v" = "completed" ]
}

@test "walks two call edges to reach the objective row" {
    # job-1 --call--> mid-1 --call--> body-1
    _knit_sqlite3 "INSERT INTO ${_KNIT_PROV_TABLE} (source_id,target_id,edge_type) VALUES ('body-1','deep-1','call');"
    _knit_sqlite3 "INSERT INTO body (id, val_loss) VALUES ('deep-1', 0.5);"
    # Remove the direct body-1 row so the walk must descend to deep-1.
    local v
    knit_search_read_objective v "job-1" "body" "val_loss"
    [ "$v" = "0.5" ]
}

@test "a NULL objective column signals failure" {
    _knit_sqlite3 "INSERT INTO body (id) VALUES ('body-1');"
    local v
    run knit_search_read_objective v "job-1" "body" "val_loss"
    [ "$status" -ne 0 ]
    knit_search_read_objective v "job-1" "body" "val_loss" || true
    [ "$v" = "" ]
}

@test "an unreachable objective row signals failure" {
    # The call edge points at body-1 but no row was inserted into body.
    local v
    run knit_search_read_objective v "job-1" "body" "val_loss"
    [ "$status" -ne 0 ]
}

@test "an empty child id signals failure" {
    local v
    run knit_search_read_objective v "" "body" "val_loss"
    [ "$status" -ne 0 ]
}

@test "a cycle in the call graph terminates the walk and fails cleanly" {
    # job-1 --call--> body-1 --call--> job-1 (a cycle); neither id is in body, so
    # the walk must terminate via the visited set rather than loop forever.
    _knit_sqlite3 "INSERT INTO ${_KNIT_PROV_TABLE} (source_id,target_id,edge_type) VALUES ('body-1','job-1','call');"
    local v
    run knit_search_read_objective v "job-1" "body" "val_loss"
    [ "$status" -ne 0 ]
}

@test "the walk reaches the objective despite a cycle back to a visited id" {
    # job-1 --call--> body-1, body-1 --call--> job-1 (cycle), body-1 --call--> deep-1.
    # job-1 is revisited and must be skipped so the walk still descends to deep-1.
    _knit_sqlite3 "INSERT INTO ${_KNIT_PROV_TABLE} (source_id,target_id,edge_type) VALUES ('body-1','job-1','call');"
    _knit_sqlite3 "INSERT INTO ${_KNIT_PROV_TABLE} (source_id,target_id,edge_type) VALUES ('body-1','deep-1','call');"
    _knit_sqlite3 "INSERT INTO body (id, val_loss) VALUES ('deep-1', 0.75);"
    local v
    knit_search_read_objective v "job-1" "body" "val_loss"
    [ "$v" = "0.75" ]
}

@test "the walk stops at the depth bound on an over-long chain" {
    # A linear call chain longer than the 64-edge bound, with the objective only
    # at the far end, so the bounded walk never reaches it and fails.
    local i vals=""
    for ((i=0; i<70; i++)); do
        vals+="('n-${i}','n-$((i+1))','call'),"
    done
    _knit_sqlite3 "INSERT INTO ${_KNIT_PROV_TABLE} (source_id,target_id,edge_type) VALUES ${vals%,};"
    _knit_sqlite3 "INSERT INTO body (id, val_loss) VALUES ('n-70', 0.9);"
    local v
    run knit_search_read_objective v "n-0" "body" "val_loss"
    [ "$status" -ne 0 ]
}
