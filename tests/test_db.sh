#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- _knit_db_create_table ----------

@test "create table creates the table in the database" {
    _knit_db_create_table "runs" "id:uuid" "duration:real"
    local result
    result=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='runs';")
    [ "$result" -eq 1 ]
}

@test "create table stores correct column names and types" {
    _knit_db_create_table "runs" "id:uuid" "count:integer" "label:string"
    local names types
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f2)
    types=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f3)
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
    name=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f2)
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
    sqlite3 "${_KNIT_DATABASE}" "INSERT INTO runs (id, count) VALUES ('550e8400-e29b-41d4-a716-446655440000', 1);"
    _knit_db_migrate_table "runs" "id:uuid" "count:integer"
    local rows
    rows=$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM runs;")
    [ "$rows" -eq 1 ]
}

@test "migrate table adds a new column" {
    _knit_db_create_table "runs" "id:uuid"
    _knit_db_migrate_table "runs" "id:uuid" "label:string=unknown"
    local col
    col=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f2 | sed -n '2p')
    [ "$col" = "label" ]
}

@test "migrate table fills new column with default for existing rows" {
    _knit_db_create_table "runs" "id:uuid"
    sqlite3 "${_KNIT_DATABASE}" "INSERT INTO runs (id) VALUES ('550e8400-e29b-41d4-a716-446655440000');"
    _knit_db_migrate_table "runs" "id:uuid" "label:string=unknown"
    local val
    val=$(sqlite3 "${_KNIT_DATABASE}" "SELECT label FROM runs;")
    [ "$val" = "unknown" ]
}

@test "migrate table drops a column" {
    _knit_db_create_table "runs" "id:uuid" "count:integer"
    _knit_db_migrate_table "runs" "id:uuid"
    local ncols
    ncols=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('runs');" | wc -l)
    [ "$ncols" -eq 1 ]
}

@test "migrate table preserves existing row values" {
    _knit_db_create_table "runs" "id:uuid" "count:integer"
    sqlite3 "${_KNIT_DATABASE}" "INSERT INTO runs (id, count) VALUES ('550e8400-e29b-41d4-a716-446655440000', 42);"
    _knit_db_migrate_table "runs" "id:uuid" "count:integer" "label:string=x"
    local val
    val=$(sqlite3 "${_KNIT_DATABASE}" "SELECT count FROM runs;")
    [ "$val" -eq 42 ]
}

@test "migrate table changes column type" {
    _knit_db_create_table "runs" "id:uuid" "score:integer"
    _knit_db_migrate_table "runs" "id:uuid" "score:real"
    local col_type
    col_type=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f3 | sed -n '2p')
    [ "$col_type" = "REAL" ]
}

@test "migrate table handles multiple simultaneous changes" {
    _knit_db_create_table "runs" "id:uuid" "old_col:integer"
    sqlite3 "${_KNIT_DATABASE}" "INSERT INTO runs (id, old_col) VALUES ('550e8400-e29b-41d4-a716-446655440000', 7);"
    _knit_db_migrate_table "runs" "id:uuid" "new_col:string=hello"
    local names col_val
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f2 | tr '\n' ',')
    col_val=$(sqlite3 "${_KNIT_DATABASE}" "SELECT new_col FROM runs;")
    [ "$names" = "id,new_col," ]
    [ "$col_val" = "hello" ]
}

@test "migrate table normalizes hyphen in column name" {
    _knit_db_create_table "runs" "id:uuid"
    _knit_db_migrate_table "runs" "id:uuid" "my-col:string=x"
    local col
    col=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f2 | sed -n '2p')
    [ "$col" = "my_col" ]
}

@test "migrate table default value with single quote is handled correctly" {
    _knit_db_create_table "runs" "id:uuid"
    sqlite3 "${_KNIT_DATABASE}" "INSERT INTO runs (id) VALUES ('550e8400-e29b-41d4-a716-446655440000');"
    _knit_db_migrate_table "runs" "id:uuid" "label:string=it's here"
    local val
    val=$(sqlite3 "${_KNIT_DATABASE}" "SELECT label FROM runs;")
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
    result=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='mycmd';")
    [ "$result" -eq 1 ]
}

@test "setup table creates id as the first column" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_table
    knit_done
    local first_col
    first_col=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | head -1)
    [ "$first_col" = "id" ]
}

@test "setup table includes required parameter as column" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_required "count:integer" "A count."
    knit_with_table
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,count," ]
}

@test "setup table includes optional parameter as column" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_optional "label:string" "default" "A label."
    knit_with_table
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,label," ]
}

@test "setup table includes flag as boolean column" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_flag "verbose" "Enable verbose output."
    knit_with_table
    knit_done
    local names types
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | tr '\n' ',')
    types=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f3 | tr '\n' ',')
    [ "$names" = "id,verbose," ]
    [ "$types" = "TEXT,TEXT," ]
}

@test "setup table includes output as column" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_output "result:real" "0.0" "The result."
    knit_with_table
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,result," ]
}

@test "setup table is a no-op when called again with same schema" {
    knit_register knit_empty "mycmd" "A test command."
    knit_with_required "count:integer" "A count."
    knit_with_table
    knit_done
    sqlite3 "${_KNIT_DATABASE}" "INSERT INTO mycmd (id, count) VALUES ('550e8400-e29b-41d4-a716-446655440000', 1);"
    # Call _knit_db_setup_table directly a second time — table must survive intact
    _knit_db_setup_table "mycmd" "mycmd"
    local rows
    rows=$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM mycmd;")
    [ "$rows" -eq 1 ]
}

@test "setup table migrates when a new output is added" {
    # First registration: one required parameter
    knit_register knit_empty "mycmd" "A test command."
    knit_with_required "count:integer" "A count."
    knit_with_table
    knit_done
    sqlite3 "${_KNIT_DATABASE}" "INSERT INTO mycmd (id, count) VALUES ('550e8400-e29b-41d4-a716-446655440000', 7);"

    # Simulate a new output being added by calling _knit_db_setup_table with
    # a modified command state (add result to outputs set directly)
    _knit_set_add "_KNIT_CMD_mycmd_outputs" "result"
    eval "_KNIT_CMD_mycmd_3_result_type=real"
    eval "_KNIT_CMD_mycmd_3_result_default=0.0"
    _knit_db_setup_table "mycmd" "mycmd"

    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,count,result," ]
    local preserved
    preserved=$(sqlite3 "${_KNIT_DATABASE}" "SELECT count FROM mycmd;")
    [ "$preserved" -eq 7 ]
}

# ---------- bootstrap guard ----------

@test "setup table is a no-op when bootstrapping and experiment is not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    # knit_done fires _knit_db_setup_table — must return 0 without creating any table
    knit_register knit_empty "guarded" "cmd"
    knit_with_table
    run knit_done
    [ "$status" -eq 0 ]
    local result
    result=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='guarded';")
    [ "$result" -eq 0 ]
}

@test "setup table defers (no-op) when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    # Table creation is deferred until bootstrap (ensured lazily on first use),
    # so knit_done must succeed without creating a table rather than fataling.
    knit_register knit_empty "guarded2" "cmd"
    knit_with_table
    run knit_done
    [ "$status" -eq 0 ]
    local result
    result=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='guarded2';")
    [ "$result" -eq 0 ]
}

# ---------- _knit_db_record_row ----------

@test "invoking a table command records a row with params, flags and outputs" {
    knit_register _t_rec_fn "reccmd" "Rec."
    knit_with_optional "label:string" "def" "A label."
    knit_with_flag "verbose" "Verbose."
    knit_with_output "result:string" "" "The result."
    knit_with_table "recs"
    _t_rec_fn() { knit_output "result" "computed"; }
    knit_done

    _knit_invoke_command "reccmd" "--label" "hello" "--verbose"

    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM recs;")" -eq 1 ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT label FROM recs;")" = "hello" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT verbose FROM recs;")" = "true" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT result FROM recs;")" = "computed" ]
    local id
    id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM recs;")
    knit_type_check "uuid" "${id}"
}

@test "recording uses declared defaults for omitted optionals and unset outputs" {
    knit_register _t_def_fn "defcmd" "Def."
    knit_with_optional "label:string" "thedefault" "A label."
    knit_with_output "result:string" "noresult" "The result."
    knit_with_table "defs"
    _t_def_fn() { :; }
    knit_done

    _knit_invoke_command "defcmd"

    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT label FROM defs;")" = "thedefault" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT result FROM defs;")" = "noresult" ]
}

@test "invoking a command without a table records nothing" {
    knit_register _t_nt_fn "ntcmd" "No table."
    _t_nt_fn() { :; }
    knit_done

    run _knit_invoke_command "ntcmd"
    [ "$status" -eq 0 ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='ntcmd';")" -eq 0 ]
}

@test "recording is skipped when _KNIT_RECORDING_SUPPRESSED is set" {
    knit_register _t_sup_fn "supcmd" "Sup."
    knit_with_optional "label:string" "def" "A label."
    knit_with_table "sups"
    _t_sup_fn() { :; }
    knit_done

    # Non-root ranks of a run set this flag so only rank 0 records the per-app
    # row; here it must prevent any row from being written.
    _KNIT_RECORDING_SUPPRESSED="1"
    _knit_invoke_command "supcmd" "--label" "hello"

    # The table is still ensured lazily on invocation, but it stays empty.
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM sups;")" -eq 0 ]
}

@test "recording proceeds when _KNIT_RECORDING_SUPPRESSED is empty (regression)" {
    knit_register _t_uns_fn "unscmd" "Uns."
    knit_with_optional "label:string" "def" "A label."
    knit_with_table "unss"
    _t_uns_fn() { :; }
    knit_done

    _KNIT_RECORDING_SUPPRESSED=""
    _knit_invoke_command "unscmd" "--label" "hello"

    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM unss;")" -eq 1 ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT label FROM unss;")" = "hello" ]
}

@test "recording escapes single quotes in values" {
    knit_register _t_esc_fn "esccmd" "Esc."
    knit_with_optional "label:string" "" "A label."
    knit_with_table "escs"
    _t_esc_fn() { :; }
    knit_done

    _knit_invoke_command "esccmd" "--label" "it's here"
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT label FROM escs;")" = "it's here" ]
}

@test "recording honours an explicit row id set with _knit_set_row_id" {
    knit_register _t_id_fn "idcmd" "Id."
    knit_with_table "ids"
    _t_id_fn() { _knit_set_row_id "11111111-1111-7111-8111-111111111111"; }
    knit_done

    _knit_invoke_command "idcmd"
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM ids;")" \
        = "11111111-1111-7111-8111-111111111111" ]
}

@test "recording uses the job UUID from KNIT_JOB_PREFIX when set" {
    knit_register _t_jp_fn "jpcmd" "Jp."
    knit_with_table "jps"
    _t_jp_fn() { :; }
    knit_done

    KNIT_JOB_PREFIX="/some/where/jobs/22222222-2222-7222-8222-222222222222" \
        _knit_invoke_command "jpcmd"
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM jps;")" \
        = "22222222-2222-7222-8222-222222222222" ]
}

@test "recording prefers KNIT_RUN_ID over KNIT_JOB_PREFIX" {
    knit_register _t_ri_fn "ricmd" "Ri."
    knit_with_table "ris"
    _t_ri_fn() { :; }
    knit_done

    # Rank 0 of a run: both are set (KNIT_JOB_PREFIX inherited from the job,
    # KNIT_RUN_ID forwarded by the launcher); the per-app row uses the run UUID.
    KNIT_JOB_PREFIX="/some/where/jobs/22222222-2222-7222-8222-222222222222" \
        KNIT_RUN_ID="33333333-3333-7333-8333-333333333333" \
        _knit_invoke_command "ricmd"
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM ris;")" \
        = "33333333-3333-7333-8333-333333333333" ]
}

# ---------- _knit_db_update_row ----------

@test "_knit_db_update_row updates a column by id" {
    _knit_db_create_table "upd" "id:uuid" "state:string"
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO upd (id, state) VALUES ('abc', 'submitted');"

    _knit_db_update_row "upd" "abc" "state=completed"
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT state FROM upd WHERE id='abc';")" \
        = "completed" ]
}

@test "_knit_db_update_row normalizes hyphenated column names" {
    _knit_db_create_table "upd2" "id:uuid" "job-name:string"
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO upd2 (id, job_name) VALUES ('abc', 'old');"

    _knit_db_update_row "upd2" "abc" "job-name=new"
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT job_name FROM upd2 WHERE id='abc';")" \
        = "new" ]
}

# ---------- concurrency ----------

@test "_knit_sqlite3_write writes and creates a lock file next to the database" {
    _knit_db_create_table "runs" "id:uuid"
    _knit_sqlite3_write "INSERT INTO runs (id) VALUES ('x');"

    [ -f "${_KNIT_DATABASE}.lock" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM runs;")" = "1" ]
}

@test "concurrent writers all land without a 'database is locked' failure" {
    _knit_db_create_table "runs" "id:uuid" "n:integer"

    local n=10 i
    for (( i = 0; i < n; i++ )); do
        _knit_sqlite3_write \
            "INSERT INTO runs (id, n) VALUES ('id-${i}', ${i});" &
    done
    wait

    # Every insert landed exactly once with its value intact.
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM runs;")" = "${n}" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(DISTINCT n) FROM runs;")" = "${n}" ]
}

@test "concurrent updates to one row serialize to a consistent final value" {
    _knit_db_create_table "runs" "id:uuid" "state:string"
    _knit_sqlite3_write "INSERT INTO runs (id, state) VALUES ('j', 'submitted');"

    local n=10 i
    for (( i = 0; i < n; i++ )); do
        _knit_db_update_row "runs" "j" "state=s-${i}" &
    done
    wait

    # The row is intact (no torn write) and holds one of the written values.
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM runs;")" = "1" ]
    local final
    final=$(sqlite3 "${_KNIT_DATABASE}" "SELECT state FROM runs WHERE id='j';")
    [[ "${final}" =~ ^s-[0-9]+$ ]]
}
