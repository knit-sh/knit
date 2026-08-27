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

@test "knit_with_artifact adds the artifact to both the outputs and artifacts sets" {
    knit_register "art_cmd_1" knit_empty "A test command."
    knit_with_artifact "table:file" "The results table."
    knit_done
    # It stays in the outputs set (so knit describe lists it), but it contributes
    # no column to the command's own table (see the schema-builder test below).
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

@test "knit_with_artifact adds no companion checksum column" {
    knit_register "art_cmd_3" knit_empty "A test command."
    knit_with_artifact "table:file" "The results table."
    knit_done
    # The digest lives in the artifacts table, so no "<name>_checksum" companion
    # column is synthesized (unlike an ordinary file output).
    run _knit_set_find "_KNIT_CMD_art_cmd_3_outputs" "table_checksum"
    [ "${status}" -ne 0 ]
}

@test "an artifact contributes no column to the command's own table" {
    _knit_metadata_store --key "__artifact_path__" \
        --value "${_KNIT_TEST_TMPDIR}/artifacts"
    knit_register "art_cols" fn_art_cols "Test."
    knit_with_table
    knit_with_output "note:string" "" "A plain output."
    knit_with_artifact "table:file" "The results table."
    fn_art_cols() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        printf 'x\n' > "${out}/table.csv"
        knit_artifact "table" "table.csv"
    }
    knit_done
    _knit_invoke_command "art_cols"
    # The plain output "note" is a column; the artifact "table" and any
    # "table_checksum" companion are NOT.
    local cols
    cols=$(sqlite3 "${_KNIT_DATABASE}" \
        "PRAGMA table_info('art_cols');" | cut -d'|' -f2 | tr '\n' ',')
    [[ "${cols}" == *"note"* ]]
    [[ "${cols}" != *"table"* ]]
}

@test "knit_with_artifact records the file/directory existence marker" {
    knit_register "art_cmd_3b" knit_empty "A test command."
    knit_with_artifact "report:dir" "The report tree."
    knit_done
    # The runtime existence/type check reads this marker even though there is no
    # companion checksum column.
    [ "${_KNIT_CMD_art_cmd_3b_fileparam_report}" = "output:directory:yes" ]
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

@test "knit_with_artifact ensures a table when the command declared none" {
    knit_register "art_cmd_15" knit_empty "A test command."
    knit_with_artifact "table:file" "The results table."
    knit_done
    # A produced edge needs a producing row, so an artifact-only command gets a
    # default table named after the command.
    [ "${_KNIT_CMD_art_cmd_15_table}" = "art_cmd_15" ]
    [ "${_KNIT_DB_REGISTERED_TABLES[art_cmd_15]}" = "art_cmd_15" ]
}

@test "knit_with_artifact leaves an explicitly declared table alone" {
    knit_register "art_cmd_16" knit_empty "A test command."
    knit_with_table "custom_tbl"
    knit_with_artifact "table:file" "The results table."
    knit_done
    [ "${_KNIT_CMD_art_cmd_16_table}" = "custom_tbl" ]
}

@test "knit_with_output rejects a name already used by an artifact" {
    knit_register "art_cmd_17" knit_empty "A test command."
    knit_with_artifact "table:file" "The results table."
    # The artifact shares the outputs name space, so the name is already taken.
    run knit_with_output "table:string" "" "Collides."
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already declared"* ]]
    knit_done
}

@test "knit_with_artifact rejects a name already used by an output" {
    knit_register "art_cmd_18" knit_empty "A test command."
    knit_with_output "table:string" "" "An ordinary output."
    run knit_with_artifact "table:file" "Collides."
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already declared"* ]]
    knit_done
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

# Read one column of the single recorded artifacts row.
_art() {
    _knit_sqlite3 "SELECT \"${1}\" FROM artifacts;"
}

# Read the source_name of the single "produced" edge.
_produced_source() {
    _knit_sqlite3 \
        "SELECT source_name FROM __provenance__ WHERE edge_type='produced';"
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
    # The artifact is recorded as a row in the artifacts table (not a column of
    # the command's own table), with the artifacts-relative path and the digest.
    [ "$(_art path)" = "table.csv" ]
    [ "$(_art name)" = "table" ]
    [ "$(_art type)" = "file" ]
    [ "$(_art result)" = "0" ]
    local expected
    _knit_sha256 expected "${_ART_ROOT}/table.csv"
    [ "$(_art checksum)" = "sha256:${expected}" ]
    # A "produced" edge links the producing invocation to the artifact row, and
    # its source id joins to the producer's own row.
    [ "$(_produced_source)" = "bind_rel" ]
    [ "$(_knit_sqlite3 \
        "SELECT target_name FROM __provenance__ WHERE edge_type='produced';")" \
        = "artifacts" ]
    [ "$(_knit_sqlite3 \
        "SELECT target_id FROM __provenance__ WHERE edge_type='produced';")" \
        = "$(_art id)" ]
    [ "$(_knit_sqlite3 \
        "SELECT source_id FROM __provenance__ WHERE edge_type='produced';")" \
        = "$(_knit_sqlite3 "SELECT id FROM bind_rel;")" ]
}

@test "knit_artifact reverse lookup recovers the producer from a file path" {
    _use_artifacts_root
    knit_register "bind_lookup" fn_bind_lookup "Test."
    knit_with_table
    knit_with_artifact "figure:file" "A figure." --result
    fn_bind_lookup() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        printf 'img\n' > "${out}/figure.png"
        knit_artifact "figure" "figure.png"
    }
    knit_done
    _knit_invoke_command "bind_lookup"
    # "How was artifacts/figure.png produced?" — one hop along the produced edge.
    local producer
    producer=$(_knit_sqlite3 \
        "SELECT p.source_name FROM __provenance__ p \
         JOIN artifacts a ON a.id = p.target_id \
         WHERE p.edge_type='produced' AND a.path='figure.png';")
    [ "${producer}" = "bind_lookup" ]
    # --result carried onto the artifacts row.
    [ "$(_art result)" = "1" ]
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
    [ "$(_art path)" = "aaa/bbb/table.csv" ]
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
    [ "$(_art path)" = "aaa/bbb/table.csv" ]
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
    [ "$(_art path)" = "table.csv" ]
    local expected
    _knit_sha256 expected "${target}"
    [ "$(_art checksum)" = "sha256:${expected}" ]
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
    [ "$(_art path)" = "report" ]
    [ "$(_art type)" = "directory" ]
    local expected
    _knit_sha256 expected "${_ART_ROOT}/report"
    [ "$(_art checksum)" = "sha256:${expected}" ]
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
    [ "$(_art path)" = "sub/dataset.h5" ]
    [ -L "${_ART_ROOT}/sub/dataset.h5" ]
    local tgt want
    tgt="$(readlink "${_ART_ROOT}/sub/dataset.h5")"
    want="$(realpath -m "${target}")"
    [ "${tgt}" = "${want}" ]
    [[ "${tgt}" == /* ]]
    local expected
    _knit_sha256 expected "${target}"
    [ "$(_art checksum)" = "sha256:${expected}" ]
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
    [ "$(_art path)" = "out/figure.svg" ]
    [ -f "${_ART_ROOT}/out/figure.svg" ]
    [ ! -L "${_ART_ROOT}/out/figure.svg" ]
    local expected
    _knit_sha256 expected "${_ART_ROOT}/out/figure.svg"
    [ "$(_art checksum)" = "sha256:${expected}" ]
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
    [ "$(_art path)" = "report" ]
    [ -d "${_ART_ROOT}/report" ]
    [ -f "${_ART_ROOT}/report/a.txt" ]
    [ -f "${_ART_ROOT}/report/sub/b.txt" ]
    local expected
    _knit_sha256 expected "${_ART_ROOT}/report"
    [ "$(_art checksum)" = "sha256:${expected}" ]
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

# ---------- knit_artifact recording (multiple / gated) ----------

@test "knit_artifact records one row and one produced edge per bound artifact" {
    _use_artifacts_root
    knit_register "bind_many" fn_bind_many "Test."
    knit_with_table
    knit_with_artifact "table:file" "A table."
    knit_with_artifact "report:directory" "A report tree."
    fn_bind_many() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}/report"
        printf 'a\n' > "${out}/table.csv"
        printf 'b\n' > "${out}/report/b.txt"
        knit_artifact "table" "table.csv"
        knit_artifact "report" "report"
    }
    knit_done
    _knit_invoke_command "bind_many"
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM artifacts;")" -eq 2 ]
    [ "$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM __provenance__ WHERE edge_type='produced';")" -eq 2 ]
    # Both edges hang off the single producing row; each targets a distinct row.
    local rid
    rid=$(_knit_sqlite3 "SELECT id FROM bind_many;")
    [ "$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM __provenance__ \
         WHERE edge_type='produced' AND source_id='${rid}';")" -eq 2 ]
    [ "$(_knit_sqlite3 \
        "SELECT COUNT(DISTINCT target_id) FROM __provenance__ \
         WHERE edge_type='produced';")" -eq 2 ]
}

@test "knit_artifact records the row, its call edge, and its produced edge atomically" {
    _use_artifacts_root
    knit_register "bind_atomic" fn_bind_atomic "Test."
    knit_with_table
    knit_with_artifact "table:file" "A table."
    fn_bind_atomic() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        printf 'a\n' > "${out}/table.csv"
        knit_artifact "table" "table.csv"
    }
    knit_done
    _knit_invoke_command "bind_atomic"
    # The producing row, its "call" edge, and its "produced" edge all landed.
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM bind_atomic;")" -eq 1 ]
    [ "$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM __provenance__ WHERE edge_type='call';")" -eq 1 ]
    [ "$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM __provenance__ WHERE edge_type='produced';")" -eq 1 ]
}

@test "knit_artifact records nothing on a suppressed rank" {
    _use_artifacts_root
    knit_register "bind_suppressed" fn_bind_suppressed "Test."
    knit_with_table
    knit_with_artifact "table:file" "A table."
    fn_bind_suppressed() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        printf 'a\n' > "${out}/table.csv"
        knit_artifact "table" "table.csv"
    }
    knit_done
    _KNIT_RECORDING_SUPPRESSED=1 _knit_invoke_command "bind_suppressed"
    # A suppressed (non-root) rank records neither the row nor any artifact.
    [ "$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master \
         WHERE type='table' AND name='artifacts';")" -eq 0 ]
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

# ==========================================================================
# The artifacts-row and produced-edge write primitives.
# ==========================================================================

# ---------- _knit_artifacts_row_sql ----------

@test "artifacts row sql lists the columns and quotes the text fields" {
    local sql
    sql=$(_knit_artifacts_row_sql "aid" "figure.png" "figure" "file" "sha256:abc" "0")
    [[ "$sql" == 'INSERT INTO "artifacts" (id, path, name, type, checksum, result) VALUES '* ]]
    [[ "$sql" == *"'aid', 'figure.png', 'figure', 'file', 'sha256:abc', 0);" ]]
}

@test "artifacts row sql emits result as a bare 1 for a declared result" {
    local sql
    sql=$(_knit_artifacts_row_sql "aid" "p" "n" "file" "cs" "1")
    [[ "$sql" == *", 1);" ]]
}

@test "artifacts row sql coerces any non-1 result to 0" {
    local sql
    sql=$(_knit_artifacts_row_sql "aid" "p" "n" "file" "cs" "")
    [[ "$sql" == *", 0);" ]]
}

@test "artifacts row sql escapes single quotes in text fields" {
    local sql
    sql=$(_knit_artifacts_row_sql "aid" "a'b" "n" "file" "cs" "0")
    [[ "$sql" == *"'a''b'"* ]]
}

# ---------- _knit_artifacts_record_sql ----------

# Set up one bound artifact for a synthetic command: the fileparam marker (for
# the kind), the per-path binding stash (name + digest), and an optional
# results-set entry, exactly as knit_with_artifact / knit_artifact would leave
# them at record time.
_stash_binding() {
    local cmd="$1" rel="$2" name="$3" kind="$4" checksum="$5" is_result="${6:-0}"
    printf -v "_KNIT_CMD_${cmd}_fileparam_${name}" '%s' "output:${kind}:yes"
    _knit_set_exists "_KNIT_CMD_${cmd}_artifact_name" \
        || declare -gA "_KNIT_CMD_${cmd}_artifact_name=()"
    _knit_set_exists "_KNIT_CMD_${cmd}_artifact_checksum" \
        || declare -gA "_KNIT_CMD_${cmd}_artifact_checksum=()"
    local -n _n="_KNIT_CMD_${cmd}_artifact_name"
    local -n _s="_KNIT_CMD_${cmd}_artifact_checksum"
    _n["${rel}"]="${name}"
    _s["${rel}"]="${checksum}"
    if [[ "${is_result}" == "1" ]]; then
        _knit_set_exists "_KNIT_CMD_${cmd}_results" \
            || _knit_set_new "_KNIT_CMD_${cmd}_results"
        _knit_set_add "_KNIT_CMD_${cmd}_results" "${name}"
    fi
}

@test "artifacts record sql is empty when the command bound no artifact" {
    local sql
    _knit_artifacts_record_sql sql "noart" "pid" "producer"
    [ -z "${sql}" ]
}

@test "artifacts record sql builds a row and a produced edge for one binding" {
    _stash_binding "prod1" "figure.png" "figure" "file" "sha256:abc" 0
    local sql
    _knit_artifacts_record_sql sql "prod1" "pid" "producer"
    _knit_prov_create_table
    _knit_artifacts_create_table
    _knit_sqlite3_write <<EOF
${sql}
EOF
    local row
    row=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT path,name,type,checksum,result FROM artifacts;")
    [ "${row}" = "figure.png|figure|file|sha256:abc|0" ]
    local edge
    edge=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT source_id,source_name,target_name,edge_type FROM __provenance__;")
    [ "${edge}" = "pid|producer|artifacts|produced" ]
    # The edge targets the artifacts row it created.
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT target_id FROM __provenance__;")" \
        = "$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM artifacts;")" ]
}

@test "artifacts record sql derives result 1 from the results set" {
    _stash_binding "prod2" "out.csv" "out" "file" "sha256:xyz" 1
    local sql
    _knit_artifacts_record_sql sql "prod2" "pid" "producer"
    [[ "${sql}" == *", 1);"* ]]
}

@test "artifacts record sql derives the directory kind from the fileparam marker" {
    _stash_binding "prod3" "report" "report" "directory" "sha256:d" 0
    local sql
    _knit_artifacts_record_sql sql "prod3" "pid" "producer"
    [[ "${sql}" == *"'report', 'directory', 'sha256:d'"* ]]
}

@test "artifacts record sql leaves the produced edge times and alias NULL" {
    _stash_binding "prod4" "f" "figure" "file" "cs" 0
    local sql
    _knit_artifacts_record_sql sql "prod4" "pid" "producer"
    [[ "${sql}" == *"'produced', NULL, NULL, NULL);"* ]]
}

@test "artifacts record sql emits one row and one edge per binding" {
    _stash_binding "prod5" "a.csv" "a" "file" "sha256:1" 0
    _stash_binding "prod5" "b.csv" "b" "file" "sha256:2" 0
    local sql
    _knit_artifacts_record_sql sql "prod5" "pid" "producer"
    _knit_prov_create_table
    _knit_artifacts_create_table
    _knit_sqlite3_write <<EOF
${sql}
EOF
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM artifacts;")" -eq 2 ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM __provenance__ WHERE edge_type='produced';")" -eq 2 ]
}
