#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup
    # The selector --when constraints are evaluated with jq.
    _KNIT_JQ_EXE="jq"
    _seed_remove_db
}

teardown() {
    knit_test_db_teardown
}

# Build a small database plus the registration state (table registry + command
# kind markers) the resolvers read, covering one table of every kind: a setup
# type with two builds sharing an instance name, a resource, two job submissions
# in a group with their body rows, a run, an app, a plain command, and a wrapper.
_seed_remove_db() {
    _knit_sqlite3 "
        CREATE TABLE jobs (id TEXT, name TEXT, \"group\" TEXT, state TEXT);
        CREATE TABLE runs (id TEXT, app TEXT);
        CREATE TABLE artifacts (id TEXT, path TEXT, type TEXT);
        CREATE TABLE \"setup:juliaenv\" (id TEXT, name TEXT, directory TEXT);
        CREATE TABLE \"resource:data\" (id TEXT, name TEXT, directory TEXT);
        CREATE TABLE julia (id TEXT);
        CREATE TABLE foo (id TEXT);
        CREATE TABLE spack (id TEXT, args TEXT);
        CREATE TABLE render (id TEXT);
        CREATE TABLE __provenance__ (source_id TEXT, source_name TEXT,
            target_id TEXT, target_name TEXT, edge_type TEXT,
            start_time INTEGER, end_time INTEGER, alias TEXT);
        INSERT INTO jobs VALUES
            ('J1','render','batch','completed'),
            ('J2','render','batch','completed');
        INSERT INTO runs VALUES ('U1','julia');
        INSERT INTO artifacts VALUES ('P1','frame.png','file');
        INSERT INTO \"setup:juliaenv\" VALUES
            ('S1','env','setups/env'),
            ('S2','env','setups/env');
        INSERT INTO \"resource:data\" VALUES ('D1','mydata','resources/mydata');
        INSERT INTO julia VALUES ('A1');
        INSERT INTO foo VALUES ('F1');
        INSERT INTO spack VALUES ('W1','install zlib');
        INSERT INTO render VALUES ('R1'),('R2');
        INSERT INTO __provenance__ VALUES
            ('J1','submit','R1','submit:render','call',1,2,NULL),
            ('J2','submit','R2','submit:render','call',1,2,NULL);
    "
    _KNIT_DB_REGISTERED_TABLES[jobs]="submit"
    _KNIT_DB_REGISTERED_TABLES[runs]="run"
    _KNIT_DB_REGISTERED_TABLES[artifacts]="artifacts"
    _KNIT_DB_REGISTERED_TABLES["setup:juliaenv"]="setup:juliaenv"
    _KNIT_DB_REGISTERED_TABLES["resource:data"]="fetch:data"
    _KNIT_DB_REGISTERED_TABLES[julia]="run:julia"
    _KNIT_DB_REGISTERED_TABLES[foo]="foo"
    _KNIT_DB_REGISTERED_TABLES[spack]="spack"
    _KNIT_DB_REGISTERED_TABLES[render]="submit:render"
    printf -v "_KNIT_CMD_setup__1__juliaenv_type" '%s' setup
    printf -v "_KNIT_CMD_fetch__1__data_type" '%s' resource
    printf -v "_KNIT_CMD_run__1__julia_type" '%s' app
    printf -v "_KNIT_CMD_foo_type" '%s' command
    printf -v "_KNIT_CMD_spack_type" '%s' wrapper
    printf -v "_KNIT_CMD_submit__1__render_type" '%s' job
}

# True if the first argument equals any of the remaining arguments.
_in() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "${x}" == "${needle}" ]] && return 0; done
    return 1
}

# ---------- command surface: describe ----------

@test "describe lists the remove group and every subcommand" {
    run knit describe --format json --only remove --recursive
    [ "$status" -eq 0 ]
    [[ "${output}" == *'"name": "remove"'* ]]
    local sub
    for sub in setup resource job run app command artifact; do
        [[ "${output}" == *"\"name\": \"${sub}\""* ]] || {
            echo "missing subcommand: ${sub}"; false
        }
    done
}

# ---------- command surface: --help renders ----------

@test "remove <subcommand> --help renders for every subcommand" {
    local sub
    for sub in setup resource job run app command artifact; do
        run _knit_invoke_command "remove" "${sub}" "--help"
        [ "$status" -eq 0 ]
        [[ "${output}" == *"Usage:"* ]]
        [[ "${output}" == *"--id"* ]]
        [[ "${output}" == *"--yes"* ]]
        [[ "${output}" == *"--dry-run"* ]]
        [[ "${output}" == *"--keep-files"* ]]
        [[ "${output}" == *"--from-root"* ]]
    done
}

@test "remove setup --help shows the id/name/type selectors" {
    run _knit_invoke_command "remove" "setup" "--help"
    [ "$status" -eq 0 ]
    [[ "${output}" == *"--id"* ]]
    [[ "${output}" == *"--name"* ]]
    [[ "${output}" == *"--type"* ]]
}

@test "remove job --help shows the group selector" {
    run _knit_invoke_command "remove" "job" "--help"
    [ "$status" -eq 0 ]
    [[ "${output}" == *"--group"* ]]
}

@test "remove artifact --help shows --path instead of --name" {
    run _knit_invoke_command "remove" "artifact" "--help"
    [ "$status" -eq 0 ]
    [[ "${output}" == *"--path"* ]]
    [[ "${output}" != *"--name"* ]]
}

# ---------- exactly-one-selector: mutual exclusion via --when ----------

@test "two selectors are fatal (--id and --name)" {
    run _knit_invoke_command "remove" "setup" "--id" "A" "--name" "B"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"must not be provided"* ]]
}

@test "two selectors are fatal (--name and --type)" {
    run _knit_invoke_command "remove" "resource" "--name" "A" "--type" "B"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"must not be provided"* ]]
}

@test "two selectors are fatal on remove job (--group and --id)" {
    run _knit_invoke_command "remove" "job" "--group" "g" "--id" "A"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"must not be provided"* ]]
}

@test "two selectors are fatal on remove artifact (--path and --id)" {
    run _knit_invoke_command "remove" "artifact" "--path" "p" "--id" "A"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"must not be provided"* ]]
}

# ---------- exactly-one-selector: presence via the body check ----------

@test "no selector is fatal (body check)" {
    run _knit_invoke_command "remove" "setup"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"exactly one selector is required"* ]]
}

@test "no selector is fatal on remove artifact (body check)" {
    run _knit_invoke_command "remove" "artifact"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"exactly one selector is required"* ]]
}

# ---------- the body wires resolution and prints the starting ids ----------

@test "remove setup --id prints the resolved starting id" {
    run _knit_invoke_command "remove" "setup" "--id" "S1"
    [ "$status" -eq 0 ]
    [[ "${output}" == *"S1"* ]]
}

@test "remove job --group prints both jobs in the group" {
    run _knit_invoke_command "remove" "job" "--group" "batch"
    [ "$status" -eq 0 ]
    [[ "${output}" == *"J1"* ]]
    [[ "${output}" == *"J2"* ]]
}

@test "remove artifact --path prints the resolved artifact id" {
    run _knit_invoke_command "remove" "artifact" "--path" "frame.png"
    [ "$status" -eq 0 ]
    [[ "${output}" == *"P1"* ]]
}

@test "remove setup --id unknown is fatal through the body" {
    run _knit_invoke_command "remove" "setup" "--id" "NOPE"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"no row with id"* ]]
}

# ---------- resolve --id (existence + kind check) ----------

@test "resolve setup --id returns the id" {
    local -a ids=()
    _knit_remove_resolve_selection ids setup --id S1
    [ "${#ids[@]}" -eq 1 ]
    [ "${ids[0]}" = "S1" ]
}

@test "resolve --id of the wrong kind is fatal with a hint" {
    run _knit_remove_resolve_selection ids setup --id J1
    [ "$status" -ne 0 ]
    [[ "${output}" == *"is a job, not a setup"* ]]
    [[ "${output}" == *"remove job --id J1"* ]]
}

@test "resolve command --id of a job is fatal (wrong kind)" {
    run _knit_remove_resolve_selection ids command --id J1
    [ "$status" -ne 0 ]
    [[ "${output}" == *"is a job, not a command"* ]]
}

@test "resolve --id that does not exist is fatal" {
    run _knit_remove_resolve_selection ids setup --id GHOST
    [ "$status" -ne 0 ]
    [[ "${output}" == *"no row with id"* ]]
}

@test "resolve job/run/app/artifact --id each resolves in its framework or own table" {
    local -a ids=()
    _knit_remove_resolve_selection ids job --id J1
    [ "${ids[0]}" = "J1" ]
    _knit_remove_resolve_selection ids run --id U1
    [ "${ids[0]}" = "U1" ]
    _knit_remove_resolve_selection ids app --id A1
    [ "${ids[0]}" = "A1" ]
    _knit_remove_resolve_selection ids artifact --id P1
    [ "${ids[0]}" = "P1" ]
    _knit_remove_resolve_selection ids command --id F1
    [ "${ids[0]}" = "F1" ]
}

# ---------- resolve --name ----------

@test "resolve setup --name scans the kind tables and returns all matches" {
    local -a ids=()
    _knit_remove_resolve_selection ids setup --name env
    [ "${#ids[@]}" -eq 2 ]
    _in S1 "${ids[@]}"
    _in S2 "${ids[@]}"
}

@test "resolve resource --name resolves from the name column" {
    local -a ids=()
    _knit_remove_resolve_selection ids resource --name mydata
    [ "${#ids[@]}" -eq 1 ]
    [ "${ids[0]}" = "D1" ]
}

@test "resolve job --name matches the jobs.name alias (may be several)" {
    local -a ids=()
    _knit_remove_resolve_selection ids job --name render
    [ "${#ids[@]}" -eq 2 ]
    _in J1 "${ids[@]}"
    _in J2 "${ids[@]}"
}

@test "resolve run --name matches the launched app column" {
    local -a ids=()
    _knit_remove_resolve_selection ids run --name julia
    [ "${#ids[@]}" -eq 1 ]
    [ "${ids[0]}" = "U1" ]
}

@test "resolve app --name selects the app's own table" {
    local -a ids=()
    _knit_remove_resolve_selection ids app --name julia
    [ "${#ids[@]}" -eq 1 ]
    [ "${ids[0]}" = "A1" ]
}

@test "resolve command --name selects a plain command table" {
    local -a ids=()
    _knit_remove_resolve_selection ids command --name foo
    [ "${#ids[@]}" -eq 1 ]
    [ "${ids[0]}" = "F1" ]
}

@test "resolve command --name covers a wrapper table" {
    local -a ids=()
    _knit_remove_resolve_selection ids command --name spack
    [ "${#ids[@]}" -eq 1 ]
    [ "${ids[0]}" = "W1" ]
}

@test "resolve --name with no match is fatal" {
    run _knit_remove_resolve_selection ids setup --name nosuch
    [ "$status" -ne 0 ]
    [[ "${output}" == *"no setup named"* ]]
}

@test "resolve app --name of an unregistered name is fatal" {
    run _knit_remove_resolve_selection ids app --name ghostapp
    [ "$status" -ne 0 ]
    [[ "${output}" == *"no app named"* ]]
}

# ---------- resolve --type ----------

@test "resolve setup --type returns every build of the type" {
    local -a ids=()
    _knit_remove_resolve_selection ids setup --type juliaenv
    [ "${#ids[@]}" -eq 2 ]
    _in S1 "${ids[@]}"
    _in S2 "${ids[@]}"
}

@test "resolve resource --type returns the type's rows" {
    local -a ids=()
    _knit_remove_resolve_selection ids resource --type data
    [ "${#ids[@]}" -eq 1 ]
    [ "${ids[0]}" = "D1" ]
}

@test "resolve job --type returns the submissions of the type via the call edge" {
    local -a ids=()
    _knit_remove_resolve_selection ids job --type render
    [ "${#ids[@]}" -eq 2 ]
    _in J1 "${ids[@]}"
    _in J2 "${ids[@]}"
}

@test "resolve --type with no match is fatal" {
    run _knit_remove_resolve_selection ids setup --type nosuch
    [ "$status" -ne 0 ]
    [[ "${output}" == *"no setup of type"* ]]
}

@test "resolve job --type with no submissions is fatal" {
    run _knit_remove_resolve_selection ids job --type ghosttype
    [ "$status" -ne 0 ]
    [[ "${output}" == *"no job of type"* ]]
}

# ---------- resolve --path / --group ----------

@test "resolve artifact --path resolves the unique path" {
    local -a ids=()
    _knit_remove_resolve_selection ids artifact --path frame.png
    [ "${#ids[@]}" -eq 1 ]
    [ "${ids[0]}" = "P1" ]
}

@test "resolve artifact --path with no match is fatal" {
    run _knit_remove_resolve_selection ids artifact --path nope.png
    [ "$status" -ne 0 ]
    [[ "${output}" == *"no artifact at path"* ]]
}

@test "resolve job --group returns every job in the group" {
    local -a ids=()
    _knit_remove_resolve_selection ids job --group batch
    [ "${#ids[@]}" -eq 2 ]
    _in J1 "${ids[@]}"
    _in J2 "${ids[@]}"
}

@test "resolve job --group with no match is fatal" {
    run _knit_remove_resolve_selection ids job --group nogroup
    [ "$status" -ne 0 ]
    [[ "${output}" == *"no job in group"* ]]
}

# ---------- the shared helpers in isolation ----------

@test "_knit_remove_require_one_selector accepts exactly one selector" {
    run _knit_remove_require_one_selector id name type -- --id "A"
    [ "$status" -eq 0 ]
}

@test "_knit_remove_require_one_selector refuses zero selectors" {
    run _knit_remove_require_one_selector id name type --
    [ "$status" -ne 0 ]
    [[ "${output}" == *"exactly one selector is required"* ]]
}

@test "_knit_remove_table_kind maps framework and owned tables" {
    local k
    _knit_remove_table_kind k jobs;               [ "${k}" = "job" ]
    _knit_remove_table_kind k runs;               [ "${k}" = "run" ]
    _knit_remove_table_kind k artifacts;          [ "${k}" = "artifact" ]
    _knit_remove_table_kind k "setup:juliaenv";   [ "${k}" = "setup" ]
    _knit_remove_table_kind k "resource:data";    [ "${k}" = "resource" ]
    _knit_remove_table_kind k julia;              [ "${k}" = "app" ]
    _knit_remove_table_kind k foo;                [ "${k}" = "command" ]
    _knit_remove_table_kind k spack;              [ "${k}" = "command" ]
    _knit_remove_table_kind k unregistered;       [ -z "${k}" ]
}

@test "_knit_remove_tables_of_kind returns the framework and registered tables" {
    local -a t=()
    _knit_remove_tables_of_kind t job;      [ "${t[0]}" = "jobs" ]
    _knit_remove_tables_of_kind t run;      [ "${t[0]}" = "runs" ]
    _knit_remove_tables_of_kind t artifact; [ "${t[0]}" = "artifacts" ]
    _knit_remove_tables_of_kind t setup
    [ "${#t[@]}" -eq 1 ]
    [ "${t[0]}" = "setup:juliaenv" ]
}

@test "_knit_remove_id_table locates an id and reports empty when absent" {
    local tbl
    _knit_remove_id_table tbl S1;    [ "${tbl}" = "setup:juliaenv" ]
    _knit_remove_id_table tbl J1;    [ "${tbl}" = "jobs" ]
    _knit_remove_id_table tbl GHOST; [ -z "${tbl}" ]
}
