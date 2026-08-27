#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _knit_create_metadata_table

    # Experiment root = the directory containing .knit.
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

# ---------- _knit_artifact_root ----------

@test "artifact root resolves a relative __artifact_path__ against the experiment root" {
    _knit_metadata_store --key "__artifact_path__" --value "artifacts"
    local out
    _knit_artifact_root out
    [ "${out}" = "${_KNIT_TEST_TMPDIR}/artifacts" ]
}

@test "artifact root honors a custom relative __artifact_path__" {
    _knit_metadata_store --key "__artifact_path__" --value "out/files"
    local out
    _knit_artifact_root out
    [ "${out}" = "${_KNIT_TEST_TMPDIR}/out/files" ]
}

@test "artifact root passes an absolute __artifact_path__ through unchanged" {
    _knit_metadata_store --key "__artifact_path__" --value "/scratch/artifacts"
    local out
    _knit_artifact_root out
    [ "${out}" = "/scratch/artifacts" ]
}

@test "artifact root falls back to artifacts when __artifact_path__ is unset" {
    local out
    _knit_artifact_root out
    [ "${out}" = "${_KNIT_TEST_TMPDIR}/artifacts" ]
}

# ---------- knit_artifact_dir ----------

@test "knit_artifact_dir prints the resolved default root" {
    run knit_artifact_dir
    [ "${status}" -eq 0 ]
    [ "${output}" = "${_KNIT_TEST_TMPDIR}/artifacts" ]
}

@test "knit_artifact_dir prints a custom relative root resolved against the experiment root" {
    _knit_metadata_store --key "__artifact_path__" --value "out/files"
    run knit_artifact_dir
    [ "${status}" -eq 0 ]
    [ "${output}" = "${_KNIT_TEST_TMPDIR}/out/files" ]
}

@test "knit_artifact_dir prints an absolute root unchanged" {
    _knit_metadata_store --key "__artifact_path__" --value "/scratch/artifacts"
    run knit_artifact_dir
    [ "${status}" -eq 0 ]
    [ "${output}" = "/scratch/artifacts" ]
}

@test "knit_artifact_dir does not create the directory" {
    run knit_artifact_dir
    [ "${status}" -eq 0 ]
    [ ! -e "${_KNIT_TEST_TMPDIR}/artifacts" ]
}

# ---------- knit_with_artifact ----------

@test "knit_with_artifact adds the output to both the outputs and artifacts sets" {
    knit_register "art_cmd_1" knit_empty "A test command."
    knit_with_artifact "table:file" "The results table."
    knit_done
    _knit_set_find "_KNIT_CMD_art_cmd_1_outputs"   "table"
    _knit_set_find "_KNIT_CMD_art_cmd_1_artifacts" "table"
}

@test "knit_with_artifact records the type, default, and description" {
    knit_register "art_cmd_2" knit_empty "A test command."
    knit_with_artifact "report:directory" "The report tree."
    knit_done
    [ "${_KNIT_CMD_art_cmd_2_3_report_type}" = "directory" ]
    [ "${_KNIT_CMD_art_cmd_2_3_report_description}" = "The report tree." ]
    [ "${_KNIT_CMD_art_cmd_2_3_report_default}" = "" ]
}

@test "knit_with_artifact adds the companion checksum column" {
    knit_register "art_cmd_3" knit_empty "A test command."
    knit_with_artifact "table:file" "The results table."
    knit_done
    _knit_set_find "_KNIT_CMD_art_cmd_3_outputs" "table_checksum"
}

@test "knit_with_artifact accepts the dir alias" {
    knit_register "art_cmd_4" knit_empty "A test command."
    knit_with_artifact "report:dir" "The report tree."
    knit_done
    _knit_set_find "_KNIT_CMD_art_cmd_4_artifacts" "report"
}

@test "knit_with_artifact rejects a non-file/directory type" {
    knit_register "art_cmd_5" knit_empty "A test command."
    run knit_with_artifact "count:integer" "A count."
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be of type"* ]]
    knit_done
}

@test "knit_with_artifact rejects an unknown type" {
    knit_register "art_cmd_6" knit_empty "A test command."
    run knit_with_artifact "thing:nosuchtype" "A thing."
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"unknown type"* ]]
    knit_done
}

@test "knit_with_artifact rejects a missing type annotation" {
    knit_register "art_cmd_7" knit_empty "A test command."
    run knit_with_artifact "table" "No type."
    [ "${status}" -ne 0 ]
    knit_done
}

@test "knit_with_artifact rejects an invalid name" {
    knit_register "art_cmd_8" knit_empty "A test command."
    run knit_with_artifact "bad name:file" "Bad name."
    [ "${status}" -ne 0 ]
    knit_done
}

@test "knit_with_artifact fails outside of knit_register" {
    run knit_with_artifact "table:file" "The results table."
    [ "${status}" -ne 0 ]
}

@test "knit_with_artifact rejects a duplicate declaration" {
    knit_register "art_cmd_9" knit_empty "A test command."
    knit_with_artifact "table:file" "First declaration."
    run knit_with_artifact "table:file" "Duplicate."
    [ "${status}" -ne 0 ]
    knit_done
}

@test "knit_with_artifact rejects a collision with a parameter" {
    knit_register "art_cmd_10" knit_empty "A test command."
    knit_with_required "table:string" "A parameter."
    run knit_with_artifact "table:file" "Collides."
    [ "${status}" -ne 0 ]
    knit_done
}

@test "knit_with_artifact is fatal on a wrapper" {
    wrap_fn() { :; }
    knit_register_wrapper "art_wrap" "wrap_fn" "A wrapper."
    run knit_with_artifact "table:file" "Nope."
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"cannot be used with a wrapper command"* ]]
    knit_done
}

@test "knit_with_artifact normalizes a hyphen in the artifact name" {
    knit_register "art_cmd_11" knit_empty "A test command."
    knit_with_artifact "my-table:file" "The results table."
    knit_done
    _knit_set_find "_KNIT_CMD_art_cmd_11_artifacts" "my_table"
    _knit_set_find "_KNIT_CMD_art_cmd_11_outputs"   "my_table"
}

# ---------- knit_with_artifact --result ----------

@test "knit_with_artifact --result also marks the artifact as a result" {
    knit_register "art_cmd_12" knit_empty "A test command."
    knit_with_artifact "table:file" "The results table." --result
    knit_done
    _knit_set_find "_KNIT_CMD_art_cmd_12_artifacts" "table"
    _knit_set_find "_KNIT_CMD_art_cmd_12_results"   "table"
}

@test "knit_with_artifact without --result leaves the results set unpopulated" {
    knit_register "art_cmd_13" knit_empty "A test command."
    knit_with_artifact "table:file" "The results table."
    knit_done
    run _knit_set_find "_KNIT_CMD_art_cmd_13_results" "table"
    [ "${status}" -ne 0 ]
}

@test "knit_with_artifact rejects an unexpected flag" {
    knit_register "art_cmd_14" knit_empty "A test command."
    run knit_with_artifact "table:file" "The results table." --bogus
    [ "${status}" -ne 0 ]
    knit_done
}

# ---------- knit_artifact (bind) ----------

# Read one column of the single recorded row of a table.
_col() {
    _knit_sqlite3 "SELECT \"${1}\" FROM '${2}';"
}

# Point the artifacts root at an absolute directory under the test tmpdir, so a
# body can write into it and its resolved root is predictable.
_use_artifacts_root() {
    _ART_ROOT="${_KNIT_TEST_TMPDIR}/artifacts"
    _knit_metadata_store --key "__artifact_path__" --value "${_ART_ROOT}"
}

@test "knit_artifact stores a relative path artifacts-relative and records its checksum" {
    _use_artifacts_root
    knit_register "bind_rel" fn_bind_rel "Test."
    knit_with_table
    knit_with_artifact "table:file" "The results table."
    fn_bind_rel() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        printf 'hello\n' > "${out}/table.csv"
        knit_artifact "table" "table.csv"
    }
    knit_done
    _knit_invoke_command "bind_rel"
    [ "$(_col table bind_rel)" = "table.csv" ]
    local expected
    _knit_sha256 expected "${_ART_ROOT}/table.csv"
    [ "$(_col table_checksum bind_rel)" = "sha256:${expected}" ]
}

@test "knit_artifact accepts an absolute-inside path and stores it artifacts-relative" {
    _use_artifacts_root
    knit_register "bind_abs" fn_bind_abs "Test."
    knit_with_table
    knit_with_artifact "table:file" "The results table."
    fn_bind_abs() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}/aaa/bbb"
        printf 'hello\n' > "${out}/aaa/bbb/table.csv"
        knit_artifact "table" "${out}/aaa/bbb/table.csv"
    }
    knit_done
    _knit_invoke_command "bind_abs"
    [ "$(_col table bind_abs)" = "aaa/bbb/table.csv" ]
}

@test "knit_artifact accepts a relative path in a nested subdirectory" {
    _use_artifacts_root
    knit_register "bind_nest" fn_bind_nest "Test."
    knit_with_table
    knit_with_artifact "table:file" "The results table."
    fn_bind_nest() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}/aaa/bbb"
        printf 'hello\n' > "${out}/aaa/bbb/table.csv"
        knit_artifact "table" "aaa/bbb/table.csv"
    }
    knit_done
    _knit_invoke_command "bind_nest"
    [ "$(_col table bind_nest)" = "aaa/bbb/table.csv" ]
}

@test "knit_artifact rejects a path outside the artifacts directory" {
    _use_artifacts_root
    local outside="${_KNIT_TEST_TMPDIR}/outside.csv"
    printf 'hello\n' > "${outside}"
    knit_register "bind_out" fn_bind_out "Test."
    knit_with_table
    knit_with_artifact "table:file" "The results table."
    # shellcheck disable=SC2317 # invoked through _knit_invoke_command
    fn_bind_out() { knit_artifact "table" "${_KNIT_TEST_TMPDIR}/outside.csv"; }
    knit_done
    run _knit_invoke_command "bind_out"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"outside the artifacts directory"* ]]
}

@test "knit_artifact accepts a symlink entry whose target is outside and checksums the target" {
    _use_artifacts_root
    local target="${_KNIT_TEST_TMPDIR}/real.csv"
    printf 'payload\n' > "${target}"
    knit_register "bind_link" fn_bind_link "Test."
    knit_with_table
    knit_with_artifact "table:file" "The results table."
    fn_bind_link() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        ln -s "${_KNIT_TEST_TMPDIR}/real.csv" "${out}/table.csv"
        knit_artifact "table" "table.csv"
    }
    knit_done
    _knit_invoke_command "bind_link"
    [ "$(_col table bind_link)" = "table.csv" ]
    local expected
    _knit_sha256 expected "${target}"
    [ "$(_col table_checksum bind_link)" = "sha256:${expected}" ]
}

@test "knit_artifact records a directory checksum recursively" {
    _use_artifacts_root
    knit_register "bind_dir" fn_bind_dir "Test."
    knit_with_table
    knit_with_artifact "report:directory" "The report tree."
    fn_bind_dir() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}/report/sub"
        printf 'a\n' > "${out}/report/a.txt"
        printf 'b\n' > "${out}/report/sub/b.txt"
        knit_artifact "report" "report"
    }
    knit_done
    _knit_invoke_command "bind_dir"
    [ "$(_col report bind_dir)" = "report" ]
    local expected
    _knit_sha256 expected "${_ART_ROOT}/report"
    [ "$(_col report_checksum bind_dir)" = "sha256:${expected}" ]
}

@test "knit_artifact is fatal when the entry does not exist" {
    _use_artifacts_root
    knit_register "bind_miss" fn_bind_miss "Test."
    knit_with_table
    knit_with_artifact "table:file" "The results table."
    # shellcheck disable=SC2317 # invoked through _knit_invoke_command
    fn_bind_miss() { knit_artifact "table" "table.csv"; }
    knit_done
    run _knit_invoke_command "bind_miss"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"was not produced"* ]]
}

@test "knit_artifact is fatal on a type mismatch" {
    _use_artifacts_root
    knit_register "bind_type" fn_bind_type "Test."
    knit_with_table
    knit_with_artifact "table:file" "The results table."
    fn_bind_type() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}/table.csv"
        knit_artifact "table" "table.csv"
    }
    knit_done
    run _knit_invoke_command "bind_type"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"was not produced"* ]]
}

@test "knit_artifact is fatal on a second bind to the same path" {
    _use_artifacts_root
    knit_register "bind_twice" fn_bind_twice "Test."
    knit_with_table
    knit_with_artifact "table:file" "The results table."
    knit_with_artifact "copy:file" "A second name for the same path."
    fn_bind_twice() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        printf 'hello\n' > "${out}/table.csv"
        knit_artifact "table" "table.csv"
        knit_artifact "copy" "table.csv"
    }
    knit_done
    run _knit_invoke_command "bind_twice"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"write-once"* ]]
}

@test "knit_artifact is fatal for an undeclared artifact name" {
    _use_artifacts_root
    knit_register "bind_undecl" fn_bind_undecl "Test."
    knit_with_table
    knit_with_output "value:string" "" "An ordinary output."
    fn_bind_undecl() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        printf 'hello\n' > "${out}/table.csv"
        knit_artifact "table" "table.csv"
    }
    knit_done
    run _knit_invoke_command "bind_undecl"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"is not a declared artifact"* ]]
}

@test "knit_artifact fails outside of a command" {
    _use_artifacts_root
    run knit_artifact "table" "table.csv"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"within a registered command function"* ]]
}

@test "knit_artifact rejects an empty path" {
    _use_artifacts_root
    knit_register "bind_empty" fn_bind_empty "Test."
    knit_with_table
    knit_with_artifact "table:file" "The results table."
    # shellcheck disable=SC2317 # invoked through _knit_invoke_command
    fn_bind_empty() { knit_artifact "table" ""; }
    knit_done
    run _knit_invoke_command "bind_empty"
    [ "${status}" -ne 0 ]
}

# ---------- knit_artifact --link-from / --copy-from ----------

@test "knit_artifact --link-from makes an absolute-target symlink, creates parents, and checksums the target" {
    _use_artifacts_root
    local target="${_KNIT_TEST_TMPDIR}/big.dat"
    printf 'payload\n' > "${target}"
    knit_register "sc_link" fn_sc_link "Test."
    knit_with_table
    knit_with_artifact "dataset:file" "Big dataset."
    fn_sc_link() {
        knit_artifact "dataset" "sub/dataset.h5" \
            --link-from "${_KNIT_TEST_TMPDIR}/big.dat"
    }
    knit_done
    _knit_invoke_command "sc_link"
    [ "$(_col dataset sc_link)" = "sub/dataset.h5" ]
    [ -L "${_ART_ROOT}/sub/dataset.h5" ]
    local tgt want
    tgt="$(readlink "${_ART_ROOT}/sub/dataset.h5")"
    want="$(realpath -m "${target}")"
    [ "${tgt}" = "${want}" ]
    [[ "${tgt}" == /* ]]
    local expected
    _knit_sha256 expected "${target}"
    [ "$(_col dataset_checksum sc_link)" = "sha256:${expected}" ]
}

@test "knit_artifact --copy-from copies a file, creates parents, and checksums the copy" {
    _use_artifacts_root
    local src="${_KNIT_TEST_TMPDIR}/src.svg"
    printf 'figure\n' > "${src}"
    knit_register "sc_copy" fn_sc_copy "Test."
    knit_with_table
    knit_with_artifact "figure:file" "A figure."
    fn_sc_copy() {
        knit_artifact "figure" "out/figure.svg" \
            --copy-from "${_KNIT_TEST_TMPDIR}/src.svg"
    }
    knit_done
    _knit_invoke_command "sc_copy"
    [ "$(_col figure sc_copy)" = "out/figure.svg" ]
    [ -f "${_ART_ROOT}/out/figure.svg" ]
    [ ! -L "${_ART_ROOT}/out/figure.svg" ]
    local expected
    _knit_sha256 expected "${_ART_ROOT}/out/figure.svg"
    [ "$(_col figure_checksum sc_copy)" = "sha256:${expected}" ]
}

@test "knit_artifact --copy-from copies a directory recursively" {
    _use_artifacts_root
    mkdir -p "${_KNIT_TEST_TMPDIR}/tree/sub"
    printf 'a\n' > "${_KNIT_TEST_TMPDIR}/tree/a.txt"
    printf 'b\n' > "${_KNIT_TEST_TMPDIR}/tree/sub/b.txt"
    knit_register "sc_copydir" fn_sc_copydir "Test."
    knit_with_table
    knit_with_artifact "report:directory" "A report tree."
    fn_sc_copydir() {
        knit_artifact "report" "report" --copy-from "${_KNIT_TEST_TMPDIR}/tree"
    }
    knit_done
    _knit_invoke_command "sc_copydir"
    [ "$(_col report sc_copydir)" = "report" ]
    [ -d "${_ART_ROOT}/report" ]
    [ -f "${_ART_ROOT}/report/a.txt" ]
    [ -f "${_ART_ROOT}/report/sub/b.txt" ]
    local expected
    _knit_sha256 expected "${_ART_ROOT}/report"
    [ "$(_col report_checksum sc_copydir)" = "sha256:${expected}" ]
}

@test "knit_artifact rejects --link-from and --copy-from together" {
    _use_artifacts_root
    printf 'x\n' > "${_KNIT_TEST_TMPDIR}/x"
    knit_register "sc_both" fn_sc_both "Test."
    knit_with_table
    knit_with_artifact "table:file" "A table."
    fn_sc_both() {
        knit_artifact "table" "table.csv" \
            --link-from "${_KNIT_TEST_TMPDIR}/x" \
            --copy-from "${_KNIT_TEST_TMPDIR}/x"
    }
    knit_done
    run _knit_invoke_command "sc_both"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"mutually exclusive"* ]]
}

@test "knit_artifact shortcut refuses to overwrite an existing on-disk entry" {
    _use_artifacts_root
    printf 'new\n' > "${_KNIT_TEST_TMPDIR}/src.csv"
    knit_register "sc_over" fn_sc_over "Test."
    knit_with_table
    knit_with_artifact "table:file" "A table."
    fn_sc_over() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        printf 'old\n' > "${out}/table.csv"
        knit_artifact "table" "table.csv" \
            --copy-from "${_KNIT_TEST_TMPDIR}/src.csv"
    }
    knit_done
    run _knit_invoke_command "sc_over"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already exists on disk"* ]]
}

@test "knit_artifact shortcut is fatal when the source does not exist" {
    _use_artifacts_root
    knit_register "sc_nosrc" fn_sc_nosrc "Test."
    knit_with_table
    knit_with_artifact "table:file" "A table."
    fn_sc_nosrc() {
        knit_artifact "table" "table.csv" \
            --link-from "${_KNIT_TEST_TMPDIR}/nope.dat"
    }
    knit_done
    run _knit_invoke_command "sc_nosrc"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"does not exist"* ]]
}

@test "knit_artifact is fatal when a shortcut has no path argument" {
    _use_artifacts_root
    knit_register "sc_noarg" fn_sc_noarg "Test."
    knit_with_table
    knit_with_artifact "table:file" "A table."
    # shellcheck disable=SC2317 # invoked through _knit_invoke_command
    fn_sc_noarg() { knit_artifact "table" "table.csv" --copy-from; }
    knit_done
    run _knit_invoke_command "sc_noarg"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"requires a path argument"* ]]
}

@test "knit_artifact rejects an unexpected argument" {
    _use_artifacts_root
    knit_register "sc_bogus" fn_sc_bogus "Test."
    knit_with_table
    knit_with_artifact "table:file" "A table."
    # shellcheck disable=SC2317 # invoked through _knit_invoke_command
    fn_sc_bogus() { knit_artifact "table" "table.csv" --bogus; }
    knit_done
    run _knit_invoke_command "sc_bogus"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"unexpected argument"* ]]
}

# ==========================================================================
# The artifacts table and its graph-node wiring.
# ==========================================================================

@test "the artifacts table is registered as a graph node label" {
    # A direct names-map entry (no owning command) resolves "artifacts" as a node
    # label; the entry maps the table to itself, like a setup or plain command.
    [ "${_KNIT_DB_REGISTERED_TABLES[artifacts]}" = "artifacts" ]
    local spec
    _knit_query_build_names spec
    [[ "${spec}" == *"artifacts=artifacts"* ]]
}

@test "the artifacts table name is fatal to reuse by a command" {
    # The names-map entry guards the reserved name exactly as an owning command
    # would: another command trying to claim "artifacts" is rejected.
    knit_register "claims_artifacts" fn_claims_artifacts "Test."
    run knit_with_table "artifacts"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already used"* ]]
}

@test "create artifacts table makes the artifacts table" {
    _knit_artifacts_create_table
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='artifacts';")
    [ "$n" -eq 1 ]
}

@test "create artifacts table defines the schema columns in order" {
    _knit_artifacts_create_table
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" \
        "PRAGMA table_info('artifacts');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,path,name,type,checksum,result," ]
}

@test "create artifacts table makes path UNIQUE" {
    _knit_artifacts_create_table
    local uniques
    uniques=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM pragma_index_list('artifacts') WHERE origin='u';")
    [ "$uniques" -eq 1 ]
    # A second row with the same path is rejected by the constraint.
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO artifacts (id, path) VALUES ('a', 'figure.png');"
    run sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO artifacts (id, path) VALUES ('b', 'figure.png');"
    [ "${status}" -ne 0 ]
}

@test "create artifacts table gives result INTEGER affinity" {
    _knit_artifacts_create_table
    local result_type
    result_type=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT type FROM pragma_table_info('artifacts') WHERE name='result';")
    [ "$result_type" = "INTEGER" ]
}

@test "create artifacts table is idempotent" {
    _knit_artifacts_create_table
    _knit_artifacts_create_table
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='artifacts';")
    [ "$n" -eq 1 ]
}

@test "ensure artifacts table creates it on a table-less database" {
    # The temp database has only the metadata table (created in setup).
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='artifacts';")" -eq 0 ]
    _knit_artifacts_ensure_table
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='artifacts';")" -eq 1 ]
}

@test "ensure artifacts table runs the create at most once per process" {
    _knit_artifacts_ensure_table
    # Drop the table, then ensure again: the per-process guard must short-circuit,
    # so the table is NOT recreated.
    sqlite3 "${_KNIT_DATABASE}" "DROP TABLE artifacts;"
    _knit_artifacts_ensure_table
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='artifacts';")" -eq 0 ]
}
