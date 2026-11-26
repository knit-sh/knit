#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # A deterministic marker location, independent of the repo's own .knit, so
    # the lock-mode resolution is controlled entirely by this test.
    _KNIT_PREFIX="$(mktemp -d)"
    _KNIT_DB_LOCK_MODE=""
    _KNIT_DB_JOURNAL_MODE=""
}

teardown() {
    rm -rf "${_KNIT_PREFIX}" \
        "${_KNIT_DATABASE}.lock" \
        "${_KNIT_DATABASE}.lock.d" \
        "${_KNIT_DATABASE}.lock.d.owner" \
        "${_KNIT_DATABASE}-wal" \
        "${_KNIT_DATABASE}-shm"
    knit_test_db_teardown
}

_write_marker() {
    printf '%s\n' "$1" > "${_KNIT_PREFIX}/db-lock"
}

_write_journal_marker() {
    printf '%s\n' "$1" > "${_KNIT_PREFIX}/db-journal"
}

# ---------- _knit_db_lock_mode ----------

@test "lock mode defaults to flock when the marker is absent" {
    local mode
    _knit_db_lock_mode mode
    [ "$mode" = "flock" ]
}

@test "lock mode reads 'mkdir' from the marker" {
    _write_marker mkdir
    local mode
    _knit_db_lock_mode mode
    [ "$mode" = "mkdir" ]
}

@test "lock mode reads 'none' from the marker" {
    _write_marker none
    local mode
    _knit_db_lock_mode mode
    [ "$mode" = "none" ]
}

@test "lock mode falls back to flock and warns on an unknown marker value" {
    _write_marker bogus
    run _knit_db_lock_mode mode
    [[ "$output" == *"Unknown database lock mode"* ]]
    # A fresh direct call (the cache stays empty in this shell; run used a
    # subshell) resolves to flock.
    local mode
    _knit_db_lock_mode mode
    [ "$mode" = "flock" ]
}

@test "lock mode caches the first resolution for the process" {
    _write_marker mkdir
    local m1 m2
    _knit_db_lock_mode m1
    [ "$m1" = "mkdir" ]
    # Change the marker behind knit's back; the cached value must stand.
    _write_marker none
    _knit_db_lock_mode m2
    [ "$m2" = "mkdir" ]
}

# ---------- _knit_sqlite3_write dispatch ----------

@test "flock mode write lands and leaves no stray directory lock" {
    _write_marker flock
    _knit_sqlite3_write "CREATE TABLE t (x TEXT); INSERT INTO t VALUES ('a');"
    [ "$(_knit_sqlite3 "SELECT x FROM t;")" = "a" ]
    [ ! -d "${_KNIT_DATABASE}.lock.d" ]
}

@test "none mode write lands and takes no lock" {
    _write_marker none
    _knit_sqlite3_write "CREATE TABLE t (x TEXT); INSERT INTO t VALUES ('a');"
    [ "$(_knit_sqlite3 "SELECT x FROM t;")" = "a" ]
    [ ! -e "${_KNIT_DATABASE}.lock" ]
    [ ! -d "${_KNIT_DATABASE}.lock.d" ]
}

@test "mkdir mode write lands and releases the directory lock" {
    _write_marker mkdir
    _knit_sqlite3_write "CREATE TABLE t (x TEXT); INSERT INTO t VALUES ('a');"
    [ "$(_knit_sqlite3 "SELECT x FROM t;")" = "a" ]
    [ ! -d "${_KNIT_DATABASE}.lock.d" ]
    [ ! -e "${_KNIT_DATABASE}.lock.d.owner" ]
    # No flock lock file is ever created in mkdir mode: its absence proves the
    # dispatch took the mkdir path rather than falling through to flock.
    [ ! -e "${_KNIT_DATABASE}.lock" ]
}

@test "mkdir mode accepts heredoc-fed statements" {
    _write_marker mkdir
    _knit_sqlite3_write <<'EOF'
CREATE TABLE t (x TEXT);
INSERT INTO t VALUES ('h');
EOF
    [ "$(_knit_sqlite3 "SELECT x FROM t;")" = "h" ]
}

# ---------- mkdir timeout ----------

@test "mkdir mode fatals with cleanup guidance when a stray lock persists" {
    _write_marker mkdir
    mkdir "${_KNIT_DATABASE}.lock.d"   # a pre-existing (stray) lock
    _KNIT_DB_LOCK_TIMEOUT_S=1
    run _knit_sqlite3_write_mkdir "CREATE TABLE t (x TEXT);"
    [ "$status" -ne 0 ]
    [[ "$output" == *"stale"* ]]
    [[ "$output" == *"rmdir"* ]]
    # The write did not happen.
    run _knit_sqlite3 "SELECT name FROM sqlite_master WHERE name='t';"
    [ -z "$output" ]
}

@test "mkdir timeout reports the recorded lock holder" {
    _write_marker mkdir
    mkdir "${_KNIT_DATABASE}.lock.d"
    printf '%s\n' "12345 @ nodeX" > "${_KNIT_DATABASE}.lock.d.owner"
    _KNIT_DB_LOCK_TIMEOUT_S=1
    run _knit_sqlite3_write_mkdir "SELECT 1;"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Last held by 12345 @ nodeX"* ]]
}

# ---------- mkdir mutual exclusion ----------

@test "mkdir mode serializes concurrent writers so every insert lands" {
    _write_marker mkdir
    _knit_sqlite3_write "CREATE TABLE t (n INTEGER);"
    local n=8 i
    for (( i = 0; i < n; i++ )); do
        _knit_sqlite3_write "INSERT INTO t VALUES (${i});" &
    done
    wait
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM t;")" -eq "$n" ]
    [ "$(_knit_sqlite3 "SELECT COUNT(DISTINCT n) FROM t;")" -eq "$n" ]
    [ ! -d "${_KNIT_DATABASE}.lock.d" ]
}

# ---------- _knit_db_journal_mode ----------

@test "journal mode defaults to delete when the marker is absent" {
    local mode
    _knit_db_journal_mode mode
    [ "$mode" = "delete" ]
}

@test "journal mode reads 'wal' from the marker" {
    _write_journal_marker wal
    local mode
    _knit_db_journal_mode mode
    [ "$mode" = "wal" ]
}

@test "journal mode reads 'delete' from the marker" {
    _write_journal_marker delete
    local mode
    _knit_db_journal_mode mode
    [ "$mode" = "delete" ]
}

@test "journal mode falls back to delete and warns on an unknown marker value" {
    _write_journal_marker bogus
    run _knit_db_journal_mode mode
    [[ "$output" == *"Unknown database journal mode"* ]]
    # A fresh direct call (the cache stays empty in this shell; run used a
    # subshell) resolves to delete.
    local mode
    _knit_db_journal_mode mode
    [ "$mode" = "delete" ]
}

@test "journal mode caches the first resolution for the process" {
    _write_journal_marker wal
    local m1 m2
    _knit_db_journal_mode m1
    [ "$m1" = "wal" ]
    # Change the marker behind knit's back; the cached value must stand.
    _write_journal_marker delete
    _knit_db_journal_mode m2
    [ "$m2" = "wal" ]
}

# ---------- _knit_db_apply_journal_mode ----------

@test "apply journal mode leaves the database in WAL when 'wal' is selected" {
    _write_journal_marker wal
    _knit_db_apply_journal_mode
    [ "$(_knit_sqlite3 "PRAGMA journal_mode;")" = "wal" ]
}

@test "apply journal mode is a no-op (rollback journal) for 'delete'" {
    _write_journal_marker delete
    _knit_db_apply_journal_mode
    # The default rollback journal reports as "delete" (or "memory" for an
    # in-memory db); either way it is never "wal".
    [ "$(_knit_sqlite3 "PRAGMA journal_mode;")" != "wal" ]
}

@test "applied WAL mode persists for a later independent connection" {
    _write_journal_marker wal
    _knit_db_apply_journal_mode
    # WAL is written into the database header, so a fresh sqlite3 process (and the
    # resolver cache cleared) reads it back without re-issuing the pragma.
    _KNIT_DB_JOURNAL_MODE=""
    [ "$(_knit_sqlite3 "PRAGMA journal_mode;")" = "wal" ]
}

# ---------- _knit_bootstrap_update_db_journal against a real database ----------

@test "update helper leaves the real database reporting wal when switching to wal" {
    _write_journal_marker delete
    # Give the database a table so it is a real, non-empty db file.
    _knit_sqlite3_write "CREATE TABLE t (x TEXT);"
    # Capture only the metadata mirror; keep the real _knit_sqlite3_write.
    eval 'knit() { :; }'

    _knit_bootstrap_update_db_journal "wal" "--db-journal" "wal"
    [ "$(cat "${_KNIT_PREFIX}/db-journal")" = "wal" ]
    _KNIT_DB_JOURNAL_MODE=""
    [ "$(_knit_sqlite3 "PRAGMA journal_mode;")" = "wal" ]
}

@test "update helper checkpoints a real wal database back to a rollback journal" {
    _write_journal_marker wal
    _knit_db_apply_journal_mode
    _knit_sqlite3_write "CREATE TABLE t (x TEXT); INSERT INTO t VALUES ('a');"
    eval 'knit() { :; }'

    _knit_bootstrap_update_db_journal "delete" "--db-journal" "delete"
    [ "$(cat "${_KNIT_PREFIX}/db-journal")" = "delete" ]
    _KNIT_DB_JOURNAL_MODE=""
    # No longer WAL, and the data that was in the WAL survived the checkpoint.
    [ "$(_knit_sqlite3 "PRAGMA journal_mode;")" != "wal" ]
    [ "$(_knit_sqlite3 "SELECT x FROM t;")" = "a" ]
}

# ---------- busy timeout is overridable at source time ----------

@test "busy timeout honours an inherited value at source time" {
    run env _KNIT_SQLITE_BUSY_TIMEOUT_MS=54321 \
        bash -c 'source "'"${BATS_TEST_DIRNAME}"'/../knit.sh"; printf "%s" "${_KNIT_SQLITE_BUSY_TIMEOUT_MS}"'
    [ "$status" -eq 0 ]
    [ "$output" = "54321" ]
}

@test "busy timeout defaults to 10000 when not inherited" {
    run env -u _KNIT_SQLITE_BUSY_TIMEOUT_MS \
        bash -c 'source "'"${BATS_TEST_DIRNAME}"'/../knit.sh"; printf "%s" "${_KNIT_SQLITE_BUSY_TIMEOUT_MS}"'
    [ "$status" -eq 0 ]
    [ "$output" = "10000" ]
}
