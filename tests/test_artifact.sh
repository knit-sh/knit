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
