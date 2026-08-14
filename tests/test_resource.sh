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

# ---------- _knit_resource_root ----------

@test "resource root resolves a relative __resource_path__ against the experiment root" {
    _knit_metadata_store --key "__resource_path__" --value "resources"
    local out
    _knit_resource_root out
    [ "${out}" = "${_KNIT_TEST_TMPDIR}/resources" ]
}

@test "resource root honors a custom relative __resource_path__" {
    _knit_metadata_store --key "__resource_path__" --value "inputs/data"
    local out
    _knit_resource_root out
    [ "${out}" = "${_KNIT_TEST_TMPDIR}/inputs/data" ]
}

@test "resource root passes an absolute __resource_path__ through unchanged" {
    _knit_metadata_store --key "__resource_path__" --value "/scratch/resources"
    local out
    _knit_resource_root out
    [ "${out}" = "/scratch/resources" ]
}

@test "resource root falls back to resources when __resource_path__ is unset" {
    local out
    _knit_resource_root out
    [ "${out}" = "${_KNIT_TEST_TMPDIR}/resources" ]
}

# ---------- knit_resource_path ----------

@test "resource path resolves an existing instance to its directory" {
    mkdir -p "${_KNIT_TEST_TMPDIR}/resources/dataset"
    run knit_resource_path "dataset"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${_KNIT_TEST_TMPDIR}/resources/dataset" ]
}

@test "resource path honors a custom __resource_path__" {
    _knit_metadata_store --key "__resource_path__" --value "inputs"
    mkdir -p "${_KNIT_TEST_TMPDIR}/inputs/dataset"
    run knit_resource_path "dataset"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${_KNIT_TEST_TMPDIR}/inputs/dataset" ]
}

@test "resource path fatals when the instance is missing" {
    run knit_resource_path "dataset"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not found"* ]]
    [[ "${output}" == *"fetch --name dataset"* ]]
}

@test "resource path validates the instance name" {
    run knit_resource_path "a/b"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Invalid name"* ]]
}
