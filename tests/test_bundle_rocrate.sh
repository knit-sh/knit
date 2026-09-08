#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup
    _KNIT_JQ_EXE="jq"

    # Start from a clean slate: the bundle arrays are global and persist.
    _KNIT_BUNDLE_REQUIRES=()
    _KNIT_BUNDLE_AUTO_REQUIRES=()
    _KNIT_BUNDLE_EXTERN=()

    # A throwaway experiment tree: .knit/knit.db, the script, knit.sh beside it,
    # one job directory with a log, and one artifact.
    BUNDLE_ROOT="$(mktemp -d)"
    mkdir -p "${BUNDLE_ROOT}/.knit" "${BUNDLE_ROOT}/jobs/018abc" \
             "${BUNDLE_ROOT}/artifacts"
    _KNIT_PREFIX="${BUNDLE_ROOT}/.knit"
    _KNIT_DATABASE="${_KNIT_PREFIX}/knit.db"
    _KNIT_SQLITE_EXE="sqlite3"
    _KNIT_IS_BOOTSTRAPPED="1"
    KNIT_SCRIPT_PATH="${BUNDLE_ROOT}/experiment.sh"
    KNIT_SCRIPT_NAME="experiment.sh"
    printf '#!/bin/bash\nsource knit.sh\n' > "${BUNDLE_ROOT}/experiment.sh"
    printf '# knit framework (test stub)\n'  > "${BUNDLE_ROOT}/knit.sh"
    printf 'hello stdout\n' > "${BUNDLE_ROOT}/jobs/018abc/.stdout"
    printf 'result data\n' > "${BUNDLE_ROOT}/artifacts/result.txt"

    _knit_create_metadata_table
    _knit_sqlite3_write \
        "INSERT INTO metadata(key,value) VALUES('__project__','montecarlo-pi');"
}

teardown() {
    rm -rf "${BUNDLE_ROOT}"
    knit_test_db_teardown
}

# Seed a small provenance graph: one submitted job (a recorded row in a "jobs"
# table), the run it launched, a setup it used, and a bootstrap edge that must be
# filtered out. Registers the jobs table so the row's columns become properties.
_seed_prov() {
    _knit_prov_create_table
    _knit_sqlite3_write \
        "INSERT INTO __provenance__ VALUES('','','018abc','submit:montecarlo','call',1690193702.1,1690193760.5,NULL);"
    _knit_sqlite3_write \
        "INSERT INTO __provenance__ VALUES('018abc','submit:montecarlo','018run','run','call',1690193710.0,1690193759.0,NULL);"
    _knit_sqlite3_write \
        "INSERT INTO __provenance__ VALUES('018setup','setup:mclib','018abc','submit:montecarlo','used_by',NULL,NULL,NULL);"
    _knit_sqlite3_write \
        "INSERT INTO __provenance__ VALUES('','','018boot','bootstrap','call',1.0,2.0,NULL);"
    _knit_sqlite3_write \
        "CREATE TABLE jobs(id TEXT, samples TEXT, state TEXT, native_cmd TEXT);"
    _knit_sqlite3_write \
        "INSERT INTO jobs VALUES('018abc','1000000','completed','sbatch exp.sh submit -- montecarlo');"
    _KNIT_DB_REGISTERED_TABLES[jobs]="submit:montecarlo"
}

# ---------- knit export ro-crate (metadata only) ----------

@test "export ro-crate writes a valid manifest with the metadata descriptor" {
    local out="${BUNDLE_ROOT}/ro-crate-metadata.json"
    run _knit_export_rocrate --output "${out}"
    [ "${status}" -eq 0 ]
    [ -f "${out}" ]
    run jq -e . "${out}"
    [ "${status}" -eq 0 ]
    # The first entity describes the metadata file itself.
    run jq -r '.["@graph"][] | select(.["@id"]=="ro-crate-metadata.json") | .["@type"]' "${out}"
    [ "${output}" = "CreativeWork" ]
    run jq -r '.["@graph"][] | select(.["@id"]=="ro-crate-metadata.json") | .conformsTo["@id"]' "${out}"
    [ "${output}" = "https://w3id.org/ro/crate/1.1" ]
    run jq -r '.["@graph"][] | select(.["@id"]=="ro-crate-metadata.json") | .about["@id"]' "${out}"
    [ "${output}" = "./" ]
}

@test "export ro-crate root Dataset conforms to the Process Run Crate profile" {
    local out="${BUNDLE_ROOT}/ro-crate-metadata.json"
    _knit_export_rocrate --output "${out}"
    run jq -r '.["@graph"][] | select(.["@id"]=="./") | .["@type"]' "${out}"
    [ "${output}" = "Dataset" ]
    run jq -r '.["@graph"][] | select(.["@id"]=="./") | .conformsTo["@id"]' "${out}"
    [ "${output}" = "https://w3id.org/ro/wfrun/process/0.5" ]
    # The root name comes from the project metadata.
    run jq -r '.["@graph"][] | select(.["@id"]=="./") | .name' "${out}"
    [ "${output}" = "montecarlo-pi" ]
}

@test "export ro-crate emits one CreateAction per recorded provenance node" {
    _seed_prov
    local out="${BUNDLE_ROOT}/ro-crate-metadata.json"
    _knit_export_rocrate --output "${out}"
    # Three nodes: submit:montecarlo, run, setup:mclib. Bootstrap is filtered.
    run jq '[.["@graph"][] | select(.["@type"]=="CreateAction")] | length' "${out}"
    [ "${output}" -eq 3 ]
    run jq -e '.["@graph"][] | select(.["@id"]=="#action-018abc")' "${out}"
    [ "${status}" -eq 0 ]
    run jq -e '.["@graph"][] | select(.["@id"]=="#action-018run")' "${out}"
    [ "${status}" -eq 0 ]
    run jq -e '.["@graph"][] | select(.["@id"]=="#action-018setup")' "${out}"
    [ "${status}" -eq 0 ]
}

@test "export ro-crate never mentions the filtered bootstrap subtree" {
    _seed_prov
    local out="${BUNDLE_ROOT}/ro-crate-metadata.json"
    _knit_export_rocrate --output "${out}"
    run jq '[.["@graph"][] | select(.name=="bootstrap")] | length' "${out}"
    [ "${output}" -eq 0 ]
}

@test "export ro-crate maps call and used_by edges to result and object" {
    _seed_prov
    local out="${BUNDLE_ROOT}/ro-crate-metadata.json"
    _knit_export_rocrate --output "${out}"
    # The submit action's result includes the nested run action (call edge)...
    run jq -e '.["@graph"][] | select(.["@id"]=="#action-018abc") | .result[] | select(.["@id"]=="#action-018run")' "${out}"
    [ "${status}" -eq 0 ]
    # ...and its object includes the setup it used (used_by edge).
    run jq -e '.["@graph"][] | select(.["@id"]=="#action-018abc") | .object[] | select(.["@id"]=="#action-018setup")' "${out}"
    [ "${status}" -eq 0 ]
    # native_cmd becomes the description; state becomes actionStatus.
    run jq -r '.["@graph"][] | select(.["@id"]=="#action-018abc") | .description' "${out}"
    [[ "${output}" == *"sbatch"* ]]
    run jq -r '.["@graph"][] | select(.["@id"]=="#action-018abc") | .actionStatus["@id"]' "${out}"
    [ "${output}" = "http://schema.org/CompletedActionStatus" ]
}

@test "export ro-crate describes packed files as File and Dataset entities" {
    local out="${BUNDLE_ROOT}/ro-crate-metadata.json"
    _knit_export_rocrate --output "${out}"
    # The experiment script is a File and a SoftwareSourceCode.
    run jq -e '.["@graph"][] | select(.["@id"]=="experiment.sh") | select(.["@type"]==["File","SoftwareSourceCode"])' "${out}"
    [ "${status}" -eq 0 ]
    # The database is a File with the sqlite media type.
    run jq -r '.["@graph"][] | select(.["@id"]==".knit/knit.db") | .encodingFormat' "${out}"
    [ "${output}" = "application/vnd.sqlite3" ]
    # The artifacts directory is a Dataset (its @id ends with a slash).
    run jq -e '.["@graph"][] | select(.["@id"]=="artifacts/") | select(.["@type"]=="Dataset")' "${out}"
    [ "${status}" -eq 0 ]
    # Every data entity is listed in the root Dataset's hasPart.
    run jq -e '.["@graph"][] | select(.["@id"]=="./") | .hasPart[] | select(.["@id"]=="experiment.sh")' "${out}"
    [ "${status}" -eq 0 ]
}

@test "export ro-crate writes to standard output with --output -" {
    run _knit_export_rocrate --output -
    [ "${status}" -eq 0 ]
    # The whole of standard output is the manifest JSON.
    printf '%s\n' "${output}" | jq -e '.["@context"]' >/dev/null
    printf '%s\n' "${output}" | jq -e '.["@graph"][] | select(.["@id"]=="./")' >/dev/null
    # No manifest file was written to the default location.
    [ ! -e "./ro-crate-metadata.json" ]
}

@test "export ro-crate defaults its output to ./ro-crate-metadata.json" {
    ( cd "${BUNDLE_ROOT}" && _knit_export_rocrate )
    [ -f "${BUNDLE_ROOT}/ro-crate-metadata.json" ]
}

# ---------- knit bundle --ro-crate (crate archive) ----------

@test "bundle --ro-crate embeds the manifest at the archive root" {
    _seed_prov
    local out="${BUNDLE_ROOT}/out.tar.gz"
    run _knit_bundle --output "${out}" --ro-crate true
    [ "${status}" -eq 0 ]
    [ -f "${out}" ]
    # The manifest sits at the archive root, not nested in a directory.
    run tar -tzf "${out}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ro-crate-metadata.json"* ]]
    local names; names="$(tar -tzf "${out}")"
    grep -qx "ro-crate-metadata.json" <<< "${names}"
}

@test "bundle --ro-crate manifest describes the packed files and actions" {
    _seed_prov
    local out="${BUNDLE_ROOT}/out.tar.gz"
    _knit_bundle --output "${out}" --ro-crate true
    local dest; dest="$(mktemp -d)"
    tar -xzf "${out}" -C "${dest}"
    [ -f "${dest}/ro-crate-metadata.json" ]
    run jq -e . "${dest}/ro-crate-metadata.json"
    [ "${status}" -eq 0 ]
    # A CreateAction per recorded node travels in the crate.
    run jq '[.["@graph"][] | select(.["@type"]=="CreateAction")] | length' "${dest}/ro-crate-metadata.json"
    [ "${output}" -eq 3 ]
    # The packed database is described as a File entity.
    run jq -e '.["@graph"][] | select(.["@id"]==".knit/knit.db")' "${dest}/ro-crate-metadata.json"
    [ "${status}" -eq 0 ]
    rm -rf "${dest}"
}

@test "bundle --ro-crate references only packed entities" {
    # With --no-db the database is not packed, so the manifest must not describe
    # it as a data entity nor list it in hasPart.
    local out="${BUNDLE_ROOT}/out.tar.gz"
    _knit_bundle --output "${out}" --ro-crate true --no-db true
    local dest; dest="$(mktemp -d)"
    tar -xzf "${out}" -C "${dest}"
    run jq '[.["@graph"][] | select(.["@id"]==".knit/knit.db")] | length' "${dest}/ro-crate-metadata.json"
    [ "${output}" -eq 0 ]
    run jq '[.["@graph"][] | select(.["@id"]=="./") | .hasPart[] | select(.["@id"]==".knit/knit.db")] | length' "${dest}/ro-crate-metadata.json"
    [ "${output}" -eq 0 ]
    # The script is still packed and still described.
    run jq -e '.["@graph"][] | select(.["@id"]=="experiment.sh")' "${dest}/ro-crate-metadata.json"
    [ "${status}" -eq 0 ]
    rm -rf "${dest}"
}

@test "bundle without --ro-crate writes no manifest" {
    local out="${BUNDLE_ROOT}/out.tar.gz"
    _knit_bundle --output "${out}"
    run tar -tzf "${out}"
    [[ "${output}" != *"ro-crate-metadata.json"* ]]
}

@test "bundle --ro-crate --dry-run lists the manifest without writing an archive" {
    local out="${BUNDLE_ROOT}/out.tar.gz"
    run _knit_bundle --output "${out}" --ro-crate true --dry-run true --list true
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ro-crate-metadata.json"* ]]
    [ ! -e "${out}" ]
}
