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
#
# The provenance graph reproduces worked examples 1-3 of the design for J1's tree:
#   S1 (setup) --used_by--> J1 (jobs)      D1 (resource) --used_by--> J1
#   J1 --call--> R1 (body) --call--> U1 (run) --call--> A1 (app)
#   R1 --produced--> P1 (artifact)
# so the downward closure of S1 is {S1,J1,R1,U1,A1,P1}, of J1 is that set minus
# S1 and D1, and A1/P1/U1 each refuse when named on their own (kept caller). J2's
# tree is just J2 --call--> R2.
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
        CREATE TABLE render (id TEXT, metrics TEXT, frame TEXT, input_data TEXT);
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
        INSERT INTO render VALUES
            ('R1','/data/metrics.json','frame.png','/in/data'),
            ('R2','','','');
        INSERT INTO __provenance__ VALUES
            ('J1','submit','R1','submit:render','call',1,2,NULL),
            ('J2','submit','R2','submit:render','call',1,2,NULL),
            ('S1','setup:juliaenv','J1','submit:render','used_by',NULL,NULL,NULL),
            ('D1','resource:data','J1','submit:render','used_by',NULL,NULL,NULL),
            ('R1','submit:render','U1','run','call',3,4,NULL),
            ('U1','run','A1','julia','call',5,6,NULL),
            ('R1','submit:render','P1','artifacts','produced',NULL,NULL,NULL);
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
    # File-parameter markers for the render job body (owner of the "render"
    # table): a plain file output "metrics", an artifact output "frame", and an
    # input "input_data". Plain-output detection keeps only "metrics".
    _knit_set_new "_KNIT_CMD_submit__1__render_fileparams"
    _knit_set_add "_KNIT_CMD_submit__1__render_fileparams" metrics frame input_data
    printf -v "_KNIT_CMD_submit__1__render_fileparam_metrics" '%s' "output:file:yes"
    printf -v "_KNIT_CMD_submit__1__render_fileparam_frame" '%s' "output:file:no"
    printf -v "_KNIT_CMD_submit__1__render_fileparam_input_data" '%s' "input:file:yes"
    _knit_set_new "_KNIT_CMD_submit__1__render_artifacts"
    _knit_set_add "_KNIT_CMD_submit__1__render_artifacts" frame
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

# ---------- the body wires resolution, closure, and refusal ----------

@test "remove setup --id prints the whole downward erase set (example 1)" {
    run _knit_invoke_command "remove" "setup" "--id" "S1"
    [ "$status" -eq 0 ]
    local id
    for id in S1 J1 R1 U1 A1 P1; do
        [[ "${output}" == *"${id}"* ]] || { echo "missing ${id}"; false; }
    done
}

@test "remove job --id keeps the setup and resource it used (example 2)" {
    run _knit_invoke_command "remove" "job" "--id" "J1"
    [ "$status" -eq 0 ]
    local id
    for id in J1 R1 U1 A1 P1; do
        [[ "${output}" == *"${id}"* ]] || { echo "missing ${id}"; false; }
    done
    # The setup S1 and resource D1 it used (used_by targets) are NOT erased.
    if _in S1 ${output}; then echo "S1 must not be erased"; false; fi
    if _in D1 ${output}; then echo "D1 must not be erased"; false; fi
}

@test "remove job --group prints the erase set of every job in the group" {
    run _knit_invoke_command "remove" "job" "--group" "batch"
    [ "$status" -eq 0 ]
    [[ "${output}" == *"J1"* ]]
    [[ "${output}" == *"J2"* ]]
    [[ "${output}" == *"R2"* ]]
}

@test "remove app --id of a callee whose caller is kept is refused (example 3)" {
    run _knit_invoke_command "remove" "app" "--id" "A1"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"is called by"* ]]
    [[ "${output}" == *"U1"* ]]
    [[ "${output}" == *"remove run --id U1"* ]]
    [[ "${output}" == *"--from-root"* ]]
}

@test "remove run --id of a run whose enclosing job is kept is refused" {
    run _knit_invoke_command "remove" "run" "--id" "U1"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"is called by"* ]]
    [[ "${output}" == *"--from-root"* ]]
}

@test "remove artifact --path on its own is refused (producer kept)" {
    run _knit_invoke_command "remove" "artifact" "--path" "frame.png"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"was produced by"* ]]
    [[ "${output}" == *"--from-root"* ]]
}

@test "remove setup --id unknown is fatal through the body" {
    run _knit_invoke_command "remove" "setup" "--id" "NOPE"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"no row with id"* ]]
}

# ---------- the body wires the --from-root whole-lineage closure ----------

@test "remove artifact --path --from-root erases the whole lineage (example 4)" {
    run _knit_invoke_command "remove" "artifact" "--path" "frame.png" "--from-root"
    [ "$status" -eq 0 ]
    # The whole call/produced tree the artifact belongs to.
    local id
    for id in P1 R1 U1 A1 J1; do
        [[ "${output}" == *"${id}"* ]] || { echo "missing ${id}"; false; }
    done
    # The setup and resource used_by the tree are left out (used_by not followed).
    if _in S1 ${output}; then echo "S1 must not be erased"; false; fi
    if _in D1 ${output}; then echo "D1 must not be erased"; false; fi
}

@test "remove app --id --from-root suppresses the callee refusal" {
    run _knit_invoke_command "remove" "app" "--id" "A1" "--from-root"
    [ "$status" -eq 0 ]
    # No refusal; the whole lineage is pulled in instead.
    [[ "${output}" != *"is called by"* ]]
    local id
    for id in A1 U1 R1 J1 P1; do
        [[ "${output}" == *"${id}"* ]] || { echo "missing ${id}"; false; }
    done
    if _in S1 ${output}; then echo "S1 must not be erased"; false; fi
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

# ---------- downward closure ----------

@test "_knit_remove_closure_downward from a setup pulls in its whole tree" {
    local -a set=()
    _knit_remove_closure_downward set S1
    [ "${#set[@]}" -eq 6 ]
    local id
    for id in S1 J1 R1 U1 A1 P1; do
        _in "${id}" "${set[@]}" || { echo "missing ${id}"; false; }
    done
}

@test "_knit_remove_closure_downward from a job stops at the used_by boundary" {
    local -a set=()
    _knit_remove_closure_downward set J1
    # The job's downstream tree, but not the setup/resource that used it.
    local id
    for id in J1 R1 U1 A1 P1; do
        _in "${id}" "${set[@]}" || { echo "missing ${id}"; false; }
    done
    if _in S1 "${set[@]}"; then echo "S1 leaked upward"; false; fi
    if _in D1 "${set[@]}"; then echo "D1 leaked upward"; false; fi
}

@test "_knit_remove_closure_downward of a leaf is just the leaf" {
    local -a set=()
    _knit_remove_closure_downward set A1
    [ "${#set[@]}" -eq 1 ]
    [ "${set[0]}" = "A1" ]
}

@test "_knit_remove_closure_downward visits each id once" {
    # Two seeds in the same tree must not duplicate the shared descendants.
    local -a set=()
    _knit_remove_closure_downward set R1 U1
    local -A seen=()
    local id
    for id in "${set[@]}"; do
        [[ -v seen["${id}"] ]] && { echo "duplicate ${id}"; false; }
        seen["${id}"]=1
    done
    for id in R1 U1 A1 P1; do
        _in "${id}" "${set[@]}" || { echo "missing ${id}"; false; }
    done
}

# ---------- whole-lineage closure (--from-root) ----------

@test "_knit_remove_closure_from_root from an artifact climbs to the whole tree" {
    local -a set=()
    _knit_remove_closure_from_root set P1
    # The connected component over call/produced: producer, its caller, and every
    # sibling the caller reached, but not the used_by providers.
    local id
    for id in P1 R1 U1 A1 J1; do
        _in "${id}" "${set[@]}" || { echo "missing ${id}"; false; }
    done
    if _in S1 "${set[@]}"; then echo "S1 leaked via used_by"; false; fi
    if _in D1 "${set[@]}"; then echo "D1 leaked via used_by"; false; fi
}

@test "_knit_remove_closure_from_root from a callee names the same tree" {
    # Naming any row in the tree selects the whole tree, not just downstream.
    local -a set=()
    _knit_remove_closure_from_root set A1
    local id
    for id in A1 U1 R1 J1 P1; do
        _in "${id}" "${set[@]}" || { echo "missing ${id}"; false; }
    done
}

@test "_knit_remove_closure_from_root leaves a used_by provider out" {
    # Seeding on the job itself: its lineage tree, never the setup/resource above.
    local -a set=()
    _knit_remove_closure_from_root set J1
    if _in S1 "${set[@]}"; then echo "S1 leaked via used_by"; false; fi
    if _in D1 "${set[@]}"; then echo "D1 leaked via used_by"; false; fi
    # J2's separate tree is not reached either.
    if _in J2 "${set[@]}"; then echo "J2 is a different tree"; false; fi
    if _in R2 "${set[@]}"; then echo "R2 is a different tree"; false; fi
}

@test "_knit_remove_closure_from_root visits each id once" {
    local -a set=()
    _knit_remove_closure_from_root set R1 U1
    local -A seen=()
    local id
    for id in "${set[@]}"; do
        [[ -v seen["${id}"] ]] && { echo "duplicate ${id}"; false; }
        seen["${id}"]=1
    done
    for id in P1 R1 U1 A1 J1; do
        _in "${id}" "${set[@]}" || { echo "missing ${id}"; false; }
    done
}

# ---------- refusal check ----------

@test "_knit_remove_check_refusal refuses a callee whose caller is kept" {
    local -a selected=(A1) erase=(A1)
    run _knit_remove_check_refusal selected erase
    [ "$status" -ne 0 ]
    [[ "${output}" == *"is called by"* ]]
    [[ "${output}" == *"U1"* ]]
}

@test "_knit_remove_check_refusal allows a callee whose caller is in the set" {
    local -a selected=(A1) erase=(A1 U1)
    _knit_remove_check_refusal selected erase
}

@test "_knit_remove_check_refusal ignores incoming used_by edges" {
    # J1 is the target only of used_by edges (from S1 and D1), never call/produced,
    # so selecting it never refuses even though S1/D1 are not in the erase set.
    local -a selected=(J1) erase=(J1)
    _knit_remove_check_refusal selected erase
}

@test "_knit_remove_check_refusal refuses a bare artifact via the produced edge" {
    local -a selected=(P1) erase=(P1)
    run _knit_remove_check_refusal selected erase
    [ "$status" -ne 0 ]
    [[ "${output}" == *"was produced by"* ]]
    [[ "${output}" == *"--from-root"* ]]
}

# ---------- id -> (table, kind) mapping and artifact metadata ----------

@test "_knit_remove_map_ids resolves the table and kind of every kind" {
    local -A id_table=() id_kind=() art_path=() art_type=()
    _knit_remove_map_ids id_table id_kind art_path art_type \
        S1 D1 J1 U1 A1 F1 W1 P1
    [ "${id_table[S1]}" = "setup:juliaenv" ]; [ "${id_kind[S1]}" = "setup" ]
    [ "${id_table[D1]}" = "resource:data" ];  [ "${id_kind[D1]}" = "resource" ]
    [ "${id_table[J1]}" = "jobs" ];           [ "${id_kind[J1]}" = "job" ]
    [ "${id_table[U1]}" = "runs" ];           [ "${id_kind[U1]}" = "run" ]
    [ "${id_table[A1]}" = "julia" ];          [ "${id_kind[A1]}" = "app" ]
    [ "${id_table[F1]}" = "foo" ];            [ "${id_kind[F1]}" = "command" ]
    [ "${id_table[W1]}" = "spack" ];          [ "${id_kind[W1]}" = "command" ]
    [ "${id_table[P1]}" = "artifacts" ];      [ "${id_kind[P1]}" = "artifact" ]
}

@test "_knit_remove_map_ids reads path and type for artifact ids only" {
    local -A id_table=() id_kind=() art_path=() art_type=()
    _knit_remove_map_ids id_table id_kind art_path art_type P1 A1
    [ "${art_path[P1]}" = "frame.png" ]
    [ "${art_type[P1]}" = "file" ]
    # A non-artifact id records no path/type entry.
    [ ! -v "art_path[A1]" ]
    [ ! -v "art_type[A1]" ]
}

@test "_knit_remove_map_ids skips an id with no known table" {
    local -A id_table=() id_kind=() art_path=() art_type=()
    _knit_remove_map_ids id_table id_kind art_path art_type A1 GHOST
    [ "${id_table[A1]}" = "julia" ]
    [ ! -v "id_table[GHOST]" ]
    [ ! -v "id_kind[GHOST]" ]
}

# ---------- plain (non-artifact) file/directory outputs ----------

@test "_knit_remove_plain_outputs lists a plain output but excludes artifacts and inputs" {
    local -A id_table=() id_kind=() art_path=() art_type=()
    _knit_remove_map_ids id_table id_kind art_path art_type R1
    local -A outs=()
    _knit_remove_plain_outputs outs id_table R1
    # The plain file output "metrics" is listed, attributed to its owning command.
    [ "${outs[/data/metrics.json]}" = "submit:render" ]
    # The artifact output ("frame.png") and the input ("/in/data") are not.
    [ ! -v "outs[frame.png]" ]
    [ ! -v "outs[/in/data]" ]
}

@test "_knit_remove_plain_outputs skips framework-table and unclassifiable rows" {
    local -A id_table=() id_kind=() art_path=() art_type=()
    _knit_remove_map_ids id_table id_kind art_path art_type J1 U1 P1 F1
    local -A outs=()
    _knit_remove_plain_outputs outs id_table J1 U1 P1 F1
    # jobs/runs/artifacts framework rows and a command with no file params
    # (foo) contribute nothing.
    [ "${#outs[@]}" -eq 0 ]
}

@test "_knit_remove_plain_outputs skips a row whose table is unknown" {
    local -A id_table=([R1]=render)
    local -A outs=()
    # GHOST has no id_table entry, so it is skipped without error.
    _knit_remove_plain_outputs outs id_table R1 GHOST
    [ "${outs[/data/metrics.json]}" = "submit:render" ]
    [ "${#outs[@]}" -eq 1 ]
}
