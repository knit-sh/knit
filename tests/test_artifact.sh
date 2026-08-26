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
