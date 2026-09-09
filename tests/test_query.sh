#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_db_setup
    # Enum-typed parameters (e.g. --format) evaluate their constraint via jq.
    _KNIT_JQ_EXE="jq"
    # Reset the live table registry so each test controls the alias map.
    _KNIT_DB_REGISTERED_TABLES=()
}

teardown() {
    knit_test_db_teardown
}

# ---------- _knit_query_read_output_opts ----------

@test "read output opts applies defaults (list, header off, empty separator)" {
    local fmt hdr sep
    _knit_query_read_output_opts fmt hdr sep
    [ "${fmt}" = "list" ]
    [ "${hdr}" = "false" ]
    [ -z "${sep}" ]
}

@test "read output opts reads provided --format/--header/--separator" {
    local fmt hdr sep
    _knit_query_read_output_opts fmt hdr sep \
        --format json --header true --separator ","
    [ "${fmt}" = "json" ]
    [ "${hdr}" = "true" ]
    [ "${sep}" = "," ]
}

@test "read output opts keeps header off when the flag is absent" {
    local fmt hdr sep
    _knit_query_read_output_opts fmt hdr sep --format csv
    [ "${fmt}" = "csv" ]
    [ "${hdr}" = "false" ]
}

# ---------- _knit_query_table_alias ----------

@test "table alias is the command name when it differs from the table" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")
    local alias
    _knit_query_table_alias alias "jobs"
    [ "${alias}" = "submit" ]
}

@test "table alias is empty when the table equals its command name" {
    _KNIT_DB_REGISTERED_TABLES=([setup:libs]="setup:libs")
    local alias
    _knit_query_table_alias alias "setup:libs"
    [ -z "${alias}" ]
}

@test "table alias is empty for an unregistered table" {
    local alias
    _knit_query_table_alias alias "nosuchtable"
    [ -z "${alias}" ]
}

# ---------- _knit_query_column_types ----------

@test "column types reads name -> SQL type from the live schema" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE widget(id TEXT, n INTEGER, ratio REAL);"
    local -A types=()
    _knit_query_column_types types "widget"
    [ "${types[id]}" = "TEXT" ]
    [ "${types[n]}" = "INTEGER" ]
    [ "${types[ratio]}" = "REAL" ]
}

@test "column types is empty for an unknown table" {
    knit_test_require_sqlite
    local -A types=([stale]="x")
    _knit_query_column_types types "nosuchtable"
    [ "${#types[@]}" -eq 0 ]
}

# ---------- _knit_query_resolve_extra ----------

@test "resolve extra with no sources yields only the current database" {
    local -a dbs=() tmps=()
    _knit_query_resolve_extra dbs tmps ""
    [ "${#dbs[@]}" -eq 1 ]
    [ "${dbs[0]}" = "${_KNIT_DATABASE}" ]
    [ "${#tmps[@]}" -eq 0 ]
}

@test "resolve extra reads a directory source's .knit/knit.db" {
    mkdir -p "${BATS_TEST_TMPDIR}/expt/.knit"
    : > "${BATS_TEST_TMPDIR}/expt/.knit/knit.db"
    local -a dbs=() tmps=()
    _knit_query_resolve_extra dbs tmps "${BATS_TEST_TMPDIR}/expt"
    [ "${dbs[0]}" = "${_KNIT_DATABASE}" ]
    [ "${dbs[1]}" = "${BATS_TEST_TMPDIR}/expt/.knit/knit.db" ]
    [ "${#tmps[@]}" -eq 0 ]
}

@test "resolve extra uses a database file source as-is" {
    : > "${BATS_TEST_TMPDIR}/other.db"
    local -a dbs=() tmps=()
    _knit_query_resolve_extra dbs tmps "${BATS_TEST_TMPDIR}/other.db"
    [ "${dbs[1]}" = "${BATS_TEST_TMPDIR}/other.db" ]
    [ "${#tmps[@]}" -eq 0 ]
}

@test "resolve extra extracts only the db member from a bundle to a temp dir" {
    # Build a bundle the way `knit bundle` writes one: members stored with no
    # leading "./" (tar -C <root> <member>), carrying the database plus another
    # file that a query never needs.
    mkdir -p "${BATS_TEST_TMPDIR}/tree/.knit"
    printf 'DBCONTENT\n' > "${BATS_TEST_TMPDIR}/tree/.knit/knit.db"
    printf 'FRAMEWORK\n'  > "${BATS_TEST_TMPDIR}/tree/knit.sh"
    tar -czf "${BATS_TEST_TMPDIR}/b.tar.gz" \
        -C "${BATS_TEST_TMPDIR}/tree" .knit/knit.db knit.sh

    local -a dbs=() tmps=()
    _knit_query_resolve_extra dbs tmps "${BATS_TEST_TMPDIR}/b.tar.gz"

    [ "${#tmps[@]}" -eq 1 ]
    [ -d "${tmps[0]}" ]
    [ "${dbs[1]}" = "${tmps[0]}/.knit/knit.db" ]
    [ -f "${dbs[1]}" ]
    grep -q "DBCONTENT" "${dbs[1]}"
    # Only the database was extracted, not the rest of the bundle.
    [ ! -e "${tmps[0]}/knit.sh" ]

    # The caller owns cleanup; removing the temp dir leaves nothing behind.
    rm -rf "${tmps[0]}"
    [ ! -e "${tmps[0]}" ]
}

@test "resolve extra keeps mixed sources in order after the current db" {
    mkdir -p "${BATS_TEST_TMPDIR}/d/.knit"; : > "${BATS_TEST_TMPDIR}/d/.knit/knit.db"
    : > "${BATS_TEST_TMPDIR}/f.db"
    local -a dbs=() tmps=()
    _knit_query_resolve_extra dbs tmps "${BATS_TEST_TMPDIR}/d,${BATS_TEST_TMPDIR}/f.db"
    [ "${dbs[0]}" = "${_KNIT_DATABASE}" ]
    [ "${dbs[1]}" = "${BATS_TEST_TMPDIR}/d/.knit/knit.db" ]
    [ "${dbs[2]}" = "${BATS_TEST_TMPDIR}/f.db" ]
}

@test "resolve extra tolerates empty fields from a trailing comma" {
    : > "${BATS_TEST_TMPDIR}/f.db"
    local -a dbs=() tmps=()
    _knit_query_resolve_extra dbs tmps "${BATS_TEST_TMPDIR}/f.db,"
    [ "${#dbs[@]}" -eq 2 ]
    [ "${dbs[1]}" = "${BATS_TEST_TMPDIR}/f.db" ]
}

@test "resolve extra fatals on a source that is not dir, db, or bundle" {
    run _knit_query_resolve_extra dbs tmps "${BATS_TEST_TMPDIR}/nope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a directory, a database file, or a bundle"* ]]
}

@test "resolve extra fatals when a directory has no .knit/knit.db" {
    mkdir -p "${BATS_TEST_TMPDIR}/empty"
    run _knit_query_resolve_extra dbs tmps "${BATS_TEST_TMPDIR}/empty"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no readable database"* ]]
}

# ---------- _knit_query_build_lens_preamble ----------

# Run a query over the lens built for the current database plus the given extra
# sources, printing the result. Assembles the preamble and prepends it to the SQL
# in a single _knit_sqlite3 session, as the query commands will.
_lens_query() {
    local sql="$1"; shift
    local -a dbs=() tmps=()
    _knit_query_resolve_extra dbs tmps "$1"
    local preamble
    _knit_query_build_lens_preamble preamble "${dbs[@]}"
    _knit_sqlite3 "${preamble}
${sql}"
}

@test "lens unions a table with the same schema across two databases" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE jobs(id TEXT, state TEXT); INSERT INTO jobs VALUES('j1','done');"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" \
        "CREATE TABLE jobs(id TEXT, state TEXT); INSERT INTO jobs VALUES('j2','run');"

    run _lens_query "SELECT id||':'||state FROM jobs ORDER BY id;" "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "j1:done" ]
    [ "${lines[1]}" = "j2:run" ]
}

@test "lens reconciles a drifted schema by NULL-filling missing columns" {
    knit_test_require_sqlite
    # The current db lacks the "extra" column the other db added.
    _knit_sqlite3_write "CREATE TABLE jobs(id TEXT, state TEXT); INSERT INTO jobs VALUES('j1','done');"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" \
        "CREATE TABLE jobs(id TEXT, state TEXT, extra TEXT); INSERT INTO jobs VALUES('j2','run','E');"

    run _lens_query \
        "SELECT id||':'||IFNULL(extra,'<null>') FROM jobs ORDER BY id;" \
        "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "j1:<null>" ]
    [ "${lines[1]}" = "j2:E" ]
}

@test "lens includes a table present in only one database" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j1');"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" \
        "CREATE TABLE jobs(id TEXT); CREATE TABLE runs(id TEXT); INSERT INTO runs VALUES('r1');"

    run _lens_query "SELECT id FROM runs;" "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "r1" ]
}

@test "lens preamble does not union metadata as a command table" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE jobs(id TEXT);
        CREATE TABLE metadata(key TEXT, value TEXT);"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" "CREATE TABLE jobs(id TEXT);"

    local -a dbs=() tmps=()
    _knit_query_resolve_extra dbs tmps "${BATS_TEST_TMPDIR}/x.db"
    local preamble
    _knit_query_build_lens_preamble preamble "${dbs[@]}"

    # A command table gets a union view; metadata is turned into platforms, not
    # unioned key/value rows.
    [[ "${preamble}" == *'CREATE TEMP VIEW "jobs"'* ]]
    [[ "${preamble}" != *'CREATE TEMP VIEW "metadata"'* ]]
}

@test "lens attaches extra databases read-only" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE jobs(id TEXT);"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" \
        "CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j2');"

    # A write against the union view's underlying attached table must be refused.
    run _lens_query "INSERT INTO p1.jobs VALUES('nope');" "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -ne 0 ]
    [[ "$output" == *"readonly"* ]]
}

@test "lens over a single database still builds a working view" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j1');"

    run _lens_query "SELECT id FROM jobs;" ""
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "j1" ]
}

# ---------- _knit_query_build_lens_preamble: platforms + executed edges ----------

# Seed the current database and an extra database, each with a metadata table
# carrying a platform fingerprint and a jobs table. NAME_A/NAME_B set the
# __platform__ of each.
_seed_two_platforms() {
    local name_a="$1" name_b="$2"
    _knit_sqlite3_write "
        CREATE TABLE metadata(key TEXT, value TEXT);
        INSERT INTO metadata VALUES('__platform__','${name_a}'),('__arch__','x86_64'),('__scheduler__','slurm');
        CREATE TABLE jobs(id TEXT, state TEXT);
        INSERT INTO jobs VALUES('j1','done');"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" "
        CREATE TABLE metadata(key TEXT, value TEXT);
        INSERT INTO metadata VALUES('__platform__','${name_b}'),('__arch__','aarch64'),('__scheduler__','pbs');
        CREATE TABLE jobs(id TEXT, state TEXT);
        INSERT INTO jobs VALUES('j2','run');"
}

@test "platforms view has one row per database with the fingerprint columns" {
    knit_test_require_sqlite
    _seed_two_platforms alpha beta

    run _lens_query "SELECT id||'/'||arch||'/'||scheduler FROM platforms ORDER BY id;" \
        "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "alpha/x86_64/slurm" ]
    [ "${lines[1]}" = "beta/aarch64/pbs" ]
}

@test "platforms view collapses identical platform rows with UNION" {
    knit_test_require_sqlite
    # Both databases claim the same platform with the same fingerprint.
    _seed_two_platforms same same
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" \
        "UPDATE metadata SET value='x86_64' WHERE key='__arch__';
         UPDATE metadata SET value='slurm' WHERE key='__scheduler__';"

    run _lens_query "SELECT count(*) FROM platforms;" "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "1" ]
}

@test "executed edges tag each row with its platform via a flat hop" {
    knit_test_require_sqlite
    _seed_two_platforms alpha beta
    # _KNIT_DB_REGISTERED_TABLES is reset per test, so the jobs table's command
    # name defaults to "jobs" -- the executed edge's target_name matches that.
    run _lens_query "
        SELECT p.id||'->'||j.id
        FROM platforms p
        JOIN __provenance__ e
          ON e.edge_type='executed' AND e.source_name='platform' AND e.source_id=p.id
        JOIN jobs j
          ON e.target_name='jobs' AND e.target_id=j.id
        ORDER BY p.id;" "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "alpha->j1" ]
    [ "${lines[1]}" = "beta->j2" ]
}

@test "executed edges carry NULL timestamps and alias" {
    knit_test_require_sqlite
    _seed_two_platforms alpha beta

    run _lens_query "
        SELECT count(*) FROM __provenance__
        WHERE edge_type='executed'
          AND start_time IS NULL AND end_time IS NULL AND alias IS NULL;" \
        "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "2" ]
}

@test "executed edge target_name is the command name for the table" {
    knit_test_require_sqlite
    _seed_two_platforms alpha beta
    # A registered table whose command name differs from the table name: the
    # executed edge must carry the command name, matching knit-graph resolution.
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")

    run _lens_query \
        "SELECT DISTINCT target_name FROM __provenance__ WHERE edge_type='executed';" \
        "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "submit" ]
}

@test "provenance view unions real edges beside the synthesized ones" {
    knit_test_require_sqlite
    _knit_sqlite3_write "
        CREATE TABLE metadata(key TEXT, value TEXT);
        INSERT INTO metadata VALUES('__platform__','alpha');
        CREATE TABLE jobs(id TEXT);
        INSERT INTO jobs VALUES('j1');
        CREATE TABLE __provenance__(source_id TEXT, source_name TEXT, target_id TEXT,
            target_name TEXT, edge_type TEXT, start_time REAL, end_time REAL, alias TEXT);
        INSERT INTO __provenance__ VALUES('s','setup','j1','jobs','used_by',NULL,NULL,NULL);"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" "
        CREATE TABLE metadata(key TEXT, value TEXT);
        INSERT INTO metadata VALUES('__platform__','beta');
        CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j2');"

    # The real used_by edge from the current db survives beside the executed edges.
    run _lens_query \
        "SELECT edge_type||':'||target_id FROM __provenance__ WHERE edge_type='used_by';" \
        "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "used_by:j1" ]
}

# ---------- query sql --extra (end to end) ----------

@test "query sql --extra reads across two databases tagged by platform" {
    knit_test_require_sqlite
    _seed_two_platforms alpha beta

    run _knit_query_sql --exec "
        SELECT p.id||':'||j.state
        FROM platforms p
        JOIN __provenance__ e
          ON e.edge_type='executed' AND e.source_name='platform' AND e.source_id=p.id
        JOIN jobs j ON e.target_name='jobs' AND e.target_id=j.id
        ORDER BY p.id;" --extra "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "alpha:done" ]
    [ "${lines[1]}" = "beta:run" ]
}

@test "query sql --extra unions a plain table across databases" {
    knit_test_require_sqlite
    _seed_two_platforms alpha beta

    run _knit_query_sql --exec "SELECT id FROM jobs ORDER BY id;" \
        --extra "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "j1" ]
    [ "${lines[1]}" = "j2" ]
}

@test "query sql without --extra queries only the current database" {
    knit_test_require_sqlite
    _seed_two_platforms alpha beta

    run _knit_query_sql --exec "SELECT id FROM jobs ORDER BY id;"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "j1" ]
}

@test "query sql --extra still rejects a non-read-only statement" {
    knit_test_require_sqlite
    _seed_two_platforms alpha beta

    run _knit_query_sql --exec "DROP TABLE jobs;" --extra "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -ne 0 ]
    [[ "$output" == *"only read-only statements are allowed"* ]]
}

@test "query sql --extra removes the bundle temp directory after running" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE metadata(key TEXT, value TEXT);
        INSERT INTO metadata VALUES('__platform__','alpha');
        CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j1');"
    # A bundle carrying a second platform's database.
    mkdir -p "${BATS_TEST_TMPDIR}/tree/.knit"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/tree/.knit/knit.db" \
        "CREATE TABLE metadata(key TEXT, value TEXT);
         INSERT INTO metadata VALUES('__platform__','beta');
         CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j2');"
    tar -czf "${BATS_TEST_TMPDIR}/b.tar.gz" \
        -C "${BATS_TEST_TMPDIR}/tree" .knit/knit.db

    # Confine bundle extraction to a controlled TMPDIR so leftovers are visible.
    export TMPDIR="${BATS_TEST_TMPDIR}/scratch"
    mkdir -p "${TMPDIR}"

    run _knit_query_sql --exec "SELECT id FROM jobs ORDER BY id;" \
        --extra "${BATS_TEST_TMPDIR}/b.tar.gz"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "j1" ]
    [ "${lines[1]}" = "j2" ]
    # No extracted bundle directory is left behind.
    [ -z "$(find "${TMPDIR}" -maxdepth 1 -name 'knit.query.*')" ]
}

# ---------- fingerprint mismatch warning ----------

@test "query sql --extra warns on same-name different-fingerprint platforms" {
    knit_test_require_sqlite
    # Both databases claim platform "poseidon" but with a different architecture.
    _knit_sqlite3_write "CREATE TABLE metadata(key TEXT,value TEXT);
        INSERT INTO metadata VALUES('__platform__','poseidon'),('__arch__','x86_64');
        CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j1');"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" \
        "CREATE TABLE metadata(key TEXT,value TEXT);
         INSERT INTO metadata VALUES('__platform__','poseidon'),('__arch__','aarch64');
         CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j2');"

    run _knit_query_sql --exec "SELECT id FROM jobs ORDER BY id;" \
        --extra "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [[ "$output" == *"differing fingerprints"* ]]
    [[ "$output" == *"poseidon"* ]]
    # Nothing is dropped: rows from both databases are still returned.
    [[ "$output" == *"j1"* ]]
    [[ "$output" == *"j2"* ]]
}

@test "query sql --extra does not warn when fingerprints match" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE metadata(key TEXT,value TEXT);
        INSERT INTO metadata VALUES('__platform__','poseidon'),('__arch__','x86_64');
        CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j1');"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" \
        "CREATE TABLE metadata(key TEXT,value TEXT);
         INSERT INTO metadata VALUES('__platform__','poseidon'),('__arch__','x86_64');
         CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j2');"

    run _knit_query_sql --exec "SELECT id FROM jobs ORDER BY id;" \
        --extra "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [[ "$output" != *"differing fingerprints"* ]]
}

@test "query sql --extra does not warn on distinct platform names" {
    knit_test_require_sqlite
    _seed_two_platforms alpha beta

    run _knit_query_sql --exec "SELECT id FROM jobs ORDER BY id;" \
        --extra "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [[ "$output" != *"differing fingerprints"* ]]
}

@test "fingerprint mismatch warning ignores an unnamed platform" {
    knit_test_require_sqlite
    # Two databases with no platform name but differing fingerprints: an empty
    # name is not a same-name claim, so it must not warn.
    _knit_sqlite3_write "CREATE TABLE metadata(key TEXT,value TEXT);
        INSERT INTO metadata VALUES('__platform__',''),('__arch__','x86_64');
        CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j1');"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" \
        "CREATE TABLE metadata(key TEXT,value TEXT);
         INSERT INTO metadata VALUES('__platform__',''),('__arch__','aarch64');
         CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('j2');"

    run _knit_query_sql --exec "SELECT id FROM jobs ORDER BY id;" \
        --extra "${BATS_TEST_TMPDIR}/x.db"
    [ "$status" -eq 0 ]
    [[ "$output" != *"differing fingerprints"* ]]
}

# ---------- _knit_query_build_catalog ----------

@test "build catalog mirrors the union schema with id TEXT and platforms" {
    knit_test_require_sqlite
    _seed_two_platforms alpha beta

    local -a dbs=() tmps=()
    _knit_query_resolve_extra dbs tmps "${BATS_TEST_TMPDIR}/x.db"
    local cat
    _knit_query_build_catalog cat "${dbs[@]}"

    run "${_KNIT_SQLITE_EXE}" "${cat}" \
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
    [[ "$output" == *"__provenance__"* ]]
    [[ "$output" == *"jobs"* ]]
    [[ "$output" == *"platforms"* ]]
    # metadata is not a catalog table.
    [[ "$output" != *"metadata"* ]]

    # jobs is a node table: its id column is declared TEXT.
    run "${_KNIT_SQLITE_EXE}" "${cat}" \
        "SELECT type FROM pragma_table_info('jobs') WHERE name='id';"
    [ "$output" = "TEXT" ]
    rm -f "${cat}"
}

@test "build catalog reconciles a drifted column into the union" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE metadata(key TEXT,value TEXT);
        INSERT INTO metadata VALUES('__platform__','alpha');
        CREATE TABLE jobs(id TEXT, state TEXT);"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" \
        "CREATE TABLE metadata(key TEXT,value TEXT);
         INSERT INTO metadata VALUES('__platform__','beta');
         CREATE TABLE jobs(id TEXT, state TEXT, note TEXT);"

    local -a dbs=() tmps=()
    _knit_query_resolve_extra dbs tmps "${BATS_TEST_TMPDIR}/x.db"
    local cat
    _knit_query_build_catalog cat "${dbs[@]}"

    # The column only the extra database has is present in the catalog jobs table.
    run "${_KNIT_SQLITE_EXE}" "${cat}" \
        "SELECT name FROM pragma_table_info('jobs') ORDER BY name;"
    [[ "$output" == *"note"* ]]
    rm -f "${cat}"
}

# ---------- query graph --extra (end to end, needs the knit-graph binary) ----------

# Point _KNIT_KNITGRAPH_EXE at the in-tree build, or skip when it is absent (it is
# not built in the unit-test environment; the live path is covered by integration).
_require_knit_graph() {
    local kg="${BATS_TEST_DIRNAME}/../knit-graph/build/src/knit-graph"
    [[ -x "${kg}" ]] || skip "knit-graph binary not built"
    _KNIT_KNITGRAPH_EXE="${kg}"
}

@test "query graph --extra spans platforms via a synthesized catalog" {
    knit_test_require_sqlite
    _require_knit_graph
    _seed_two_platforms alpha beta

    run _knit_query_graph --extra "${BATS_TEST_TMPDIR}/x.db" --exec \
        "MATCH (p:platform)-[:executed]->(j:jobs) RETURN p.id, j.state ORDER BY p.id"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "alpha|done" ]
    [ "${lines[1]}" = "beta|run" ]
}

@test "query graph --extra aggregates correctly across platforms" {
    knit_test_require_sqlite
    _require_knit_graph
    _knit_sqlite3_write "CREATE TABLE metadata(key TEXT,value TEXT);
        INSERT INTO metadata VALUES('__platform__','alpha');
        CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('a1'),('a2'),('a3');"
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" \
        "CREATE TABLE metadata(key TEXT,value TEXT);
         INSERT INTO metadata VALUES('__platform__','beta');
         CREATE TABLE jobs(id TEXT); INSERT INTO jobs VALUES('b1');"

    run _knit_query_graph --extra "${BATS_TEST_TMPDIR}/x.db" --exec \
        "MATCH (p:platform)-[:executed]->(j:jobs) RETURN p.id, count(j.id) ORDER BY p.id"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "alpha|3" ]
    [ "${lines[1]}" = "beta|1" ]
}

@test "query graph --extra transpiles against the drifted union schema" {
    knit_test_require_sqlite
    _require_knit_graph
    _knit_sqlite3_write "CREATE TABLE metadata(key TEXT,value TEXT);
        INSERT INTO metadata VALUES('__platform__','alpha');
        CREATE TABLE jobs(id TEXT, state TEXT); INSERT INTO jobs VALUES('j1','done');"
    # Only the extra database's jobs has a "note" column.
    "${_KNIT_SQLITE_EXE}" "${BATS_TEST_TMPDIR}/x.db" \
        "CREATE TABLE metadata(key TEXT,value TEXT);
         INSERT INTO metadata VALUES('__platform__','beta');
         CREATE TABLE jobs(id TEXT, state TEXT, note TEXT);
         INSERT INTO jobs VALUES('j2','run','N');"

    run _knit_query_graph --extra "${BATS_TEST_TMPDIR}/x.db" --exec \
        "MATCH (p:platform)-[:executed]->(j:jobs) WHERE j.note = 'N' RETURN p.id"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "beta" ]
}

@test "query graph --explain --extra prints the transpiled SQL without running it" {
    knit_test_require_sqlite
    _require_knit_graph
    _seed_two_platforms alpha beta

    run _knit_query_graph --extra "${BATS_TEST_TMPDIR}/x.db" --explain true --exec \
        "MATCH (p:platform)-[:executed]->(j:jobs) RETURN p.id"
    [ "$status" -eq 0 ]
    # It is SQL over the lens views, not query results.
    [[ "$output" == *"__provenance__"* ]]
    [[ "$output" == *"platforms"* ]]
    [[ "$output" != *"alpha"* ]]
}

@test "query graph without --extra still runs directly on the current database" {
    knit_test_require_sqlite
    _require_knit_graph
    _seed_two_platforms alpha beta

    # No platforms node without --extra; a plain node query hits only the current db.
    run _knit_query_graph --exec "MATCH (j:jobs) RETURN j.id ORDER BY j.id"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "j1" ]
}

# ---------- _knit_query_annotate_catalog ----------

@test "annotate catalog appends command aliases and column types" {
    _KNIT_DB_REGISTERED_TABLES=(
        [jobs]="submit" [montecarlo]="submit:montecarlo" [setup:libs]="setup:libs"
    )
    # Stub the type lookup so the test controls the schema.
    _knit_query_column_types() {
        local -n __knit_ret=$1
        local table="$2"
        __knit_ret=()
        case "${table}" in
            jobs)       __knit_ret=([id]="TEXT" [state]="TEXT") ;;
            montecarlo) __knit_ret=([id]="TEXT") ;;
            setup:libs) __knit_ret=([id]="TEXT") ;;
        esac
    }
    run _knit_query_annotate_catalog <<'EOF'
table jobs
  column id
  column state
table montecarlo
  column id
table setup:libs
  column id
EOF
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "table jobs (command: submit)" ]]
    [[ "${lines[1]}" == "  column id (TEXT)" ]]
    [[ "${lines[2]}" == "  column state (TEXT)" ]]
    [[ "${lines[3]}" == "table montecarlo (command: submit:montecarlo)" ]]
    [[ "${lines[4]}" == "  column id (TEXT)" ]]
    [[ "${lines[5]}" == "table setup:libs" ]]
    [[ "${lines[6]}" == "  column id (TEXT)" ]]
}

@test "annotate catalog leaves a column with no known type unchanged" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")
    _knit_query_column_types() { local -n __knit_ret=$1; __knit_ret=(); }
    run _knit_query_annotate_catalog <<'EOF'
table jobs
  column id
EOF
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "table jobs (command: submit)" ]]
    [[ "${lines[1]}" == "  column id" ]]
}

@test "annotate catalog passes a TABLE.COLUMN validation line through unchanged" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")
    _knit_query_column_types() { local -n __knit_ret=$1; __knit_ret=(); }
    run _knit_query_annotate_catalog <<'EOF'
jobs.state
EOF
    [ "$status" -eq 0 ]
    [ "${output}" = "jobs.state" ]
}

# ---------- knit query catalog ----------

@test "query catalog forwards --catalog and the database, and annotates" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    # Stub the knit-graph resolver: record its argv and emit a fake catalog.
    _knit_knit_graph() {
        printf '%s\n' "$*" > "${argfile}"
        printf 'table jobs\n  column id\n'
    }
    run knit query catalog
    [ "$status" -eq 0 ]
    [ "$(cat "${argfile}")" = "--catalog ${_KNIT_DATABASE}" ]
    [[ "${lines[0]}" == "table jobs (command: submit)" ]]
    [[ "${lines[1]}" == "  column id" ]]
}

@test "query catalog forwards the --ref TABLE reference" {
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() {
        printf '%s\n' "$*" > "${argfile}"
        printf 'table montecarlo\n  column id\n'
    }
    run knit query catalog --ref montecarlo
    [ "$status" -eq 0 ]
    [ "$(cat "${argfile}")" = "--catalog ${_KNIT_DATABASE} montecarlo" ]
}

@test "query catalog forwards a --ref TABLE.COLUMN reference" {
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() {
        printf '%s\n' "$*" > "${argfile}"
        printf 'montecarlo.pi\n'
    }
    run knit query catalog --ref montecarlo.pi
    [ "$status" -eq 0 ]
    [ "$(cat "${argfile}")" = "--catalog ${_KNIT_DATABASE} montecarlo.pi" ]
}

@test "query catalog propagates knit-graph's non-zero exit" {
    _knit_knit_graph() { return 3; }
    run knit query catalog --ref nosuchtable
    [ "$status" -eq 3 ]
}

# ---------- _knit_query_build_names ----------

@test "build names emits a sorted table=command SPEC" {
    _KNIT_DB_REGISTERED_TABLES=(
        [jobs]="submit" [montecarlo]="submit:montecarlo" [setup:libs]="setup:libs"
    )
    local spec
    _knit_query_build_names spec
    [ "${spec}" = "jobs=submit
montecarlo=submit:montecarlo
setup:libs=setup:libs" ]
}

@test "build names is empty when no table is registered" {
    local spec="unset"
    _knit_query_build_names spec
    [ -z "${spec}" ]
}

# ---------- _knit_query_graph_output_flags ----------

@test "graph output flags map format to -<mode> and default header off" {
    local -a flags
    _knit_query_graph_output_flags flags "list" "false" ""
    [ "${flags[*]}" = "-list -noheader" ]
}

@test "graph output flags emit -header and -separator when requested" {
    local -a flags
    _knit_query_graph_output_flags flags "json" "true" ","
    [ "${flags[*]}" = "-json -header -separator ," ]
}

# ---------- knit query graph ----------

@test "query graph forwards names, output flags, database and Cypher" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() { printf '%s\n' "$*" > "${argfile}"; }
    run knit query graph --exec "MATCH (j:\`jobs\`) RETURN j.id"
    [ "$status" -eq 0 ]
    [ "$(cat "${argfile}")" = "--names jobs=submit -list -noheader ${_KNIT_DATABASE} MATCH (j:\`jobs\`) RETURN j.id" ]
}

@test "query graph honours --format/--header/--separator" {
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() { printf '%s\n' "$*" > "${argfile}"; }
    run knit query graph --format json --header --separator ";" --exec "MATCH (n) RETURN n"
    [ "$status" -eq 0 ]
    [[ "$(cat "${argfile}")" == *"-json -header -separator ; ${_KNIT_DATABASE} MATCH (n) RETURN n" ]]
}

@test "query graph passes --explain through to knit-graph" {
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() { printf '%s\n' "$*" > "${argfile}"; }
    run knit query graph --explain --exec "MATCH (n) RETURN n"
    [ "$status" -eq 0 ]
    [[ "$(cat "${argfile}")" == "--explain "* ]]
    [[ "$(cat "${argfile}")" == *"${_KNIT_DATABASE} MATCH (n) RETURN n" ]]
}

@test "query graph --ast omits database, names and output flags" {
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() { printf '%s\n' "$*" > "${argfile}"; }
    run knit query graph --ast --exec "MATCH (n) RETURN n"
    [ "$status" -eq 0 ]
    [ "$(cat "${argfile}")" = "--ast MATCH (n) RETURN n" ]
}

@test "query graph forwards args after -- verbatim" {
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() { printf '%s\n' "$*" > "${argfile}"; }
    run knit query graph --exec "MATCH (n) RETURN n" -- -newline "@"
    [ "$status" -eq 0 ]
    [[ "$(cat "${argfile}")" == *"MATCH (n) RETURN n -newline @" ]]
}

@test "query graph rejects --explain together with --ast" {
    # Exclusivity is enforced declaratively by the --when constraint on --ast
    # (see the registration), which rejects --ast whenever --explain is set.
    _knit_knit_graph() { return 0; }
    run knit query graph --explain --ast --exec "MATCH (n) RETURN n"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"--ast must not be provided"* ]]
}

@test "query graph propagates knit-graph's non-zero exit" {
    _knit_knit_graph() { return 4; }
    run knit query graph --exec "MATCH (n) RETURN n"
    [ "$status" -eq 4 ]
}

# ---------- knit query sql ----------

@test "query sql forwards mode args and the SQL to sqlite3" {
    local argfile="${BATS_TEST_TMPDIR}/sql-args"
    _knit_sqlite3() { printf '%s\n' "$*" > "${argfile}"; }
    run knit query sql --exec "SELECT 1"
    [ "$status" -eq 0 ]
    [ "$(cat "${argfile}")" = "-cmd .mode list -cmd .headers off SELECT 1" ]
}

@test "query sql honours --format/--header/--separator" {
    local argfile="${BATS_TEST_TMPDIR}/sql-args"
    _knit_sqlite3() { printf '%s\n' "$*" > "${argfile}"; }
    run knit query sql --format csv --header --separator ";" --exec "SELECT 1"
    [ "$status" -eq 0 ]
    [ "$(cat "${argfile}")" = "-cmd .mode csv -cmd .headers on -cmd .separator ; SELECT 1" ]
}

@test "query sql rejects a non-read-only statement" {
    _knit_sqlite3() { printf 'RAN\n'; }
    run knit query sql --exec "DROP TABLE runs"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"read-only"* ]]
    [[ "${output}" != *"RAN"* ]]
}

@test "query sql rejects a piggy-backed write" {
    _knit_sqlite3() { printf 'RAN\n'; }
    run knit query sql --exec "SELECT 1; DROP TABLE runs"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"read-only"* ]]
}

@test "query sql propagates sqlite3's non-zero exit" {
    _knit_sqlite3() { return 5; }
    run knit query sql --exec "SELECT 1"
    [ "$status" -eq 5 ]
}

@test "query sql formats a real read query end-to-end" {
    knit_test_require_sqlite
    _knit_sqlite3_write "CREATE TABLE t(name TEXT, n INT);"
    _knit_sqlite3_write "INSERT INTO t VALUES('alice', 2), ('bob', 1);"
    run knit query sql --format list --header --separator "," \
        --exec "SELECT name, n FROM t ORDER BY n;"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'name,n\nbob,1\nalice,2')" ]
}
