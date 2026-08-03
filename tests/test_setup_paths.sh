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

# ---------- _knit_experiment_root ----------

@test "experiment root strips the trailing .knit component" {
    local root
    _knit_experiment_root root
    [ "${root}" = "${_KNIT_TEST_TMPDIR}" ]
}

# ---------- _knit_resolve_experiment_path ----------

@test "resolve resolves a relative value against the experiment root" {
    local out
    _knit_resolve_experiment_path out "results/jobs"
    [ "${out}" = "${_KNIT_TEST_TMPDIR}/results/jobs" ]
}

@test "resolve passes an absolute value through unchanged" {
    local out
    _knit_resolve_experiment_path out "/scratch/${USER}/jobs"
    [ "${out}" = "/scratch/${USER}/jobs" ]
}

# ---------- _knit_setup_root ----------

@test "setup root resolves a relative __setup_path__ against the experiment root" {
    _knit_metadata_store --key "__setup_path__" --value "setups"
    local out
    _knit_setup_root out
    [ "${out}" = "${_KNIT_TEST_TMPDIR}/setups" ]
}

@test "setup root honors a custom relative __setup_path__" {
    _knit_metadata_store --key "__setup_path__" --value "envs/mine"
    local out
    _knit_setup_root out
    [ "${out}" = "${_KNIT_TEST_TMPDIR}/envs/mine" ]
}

@test "setup root passes an absolute __setup_path__ through unchanged" {
    _knit_metadata_store --key "__setup_path__" --value "/scratch/setups"
    local out
    _knit_setup_root out
    [ "${out}" = "/scratch/setups" ]
}

@test "setup root falls back to setups when __setup_path__ is unset" {
    local out
    _knit_setup_root out
    [ "${out}" = "${_KNIT_TEST_TMPDIR}/setups" ]
}

# ---------- _knit_job_root ----------

@test "job root resolves a relative __job_path__ against the experiment root" {
    _knit_metadata_store --key "__job_path__" --value "jobs"
    local out
    _knit_job_root out
    [ "${out}" = "${_KNIT_TEST_TMPDIR}/jobs" ]
}

@test "job root passes an absolute __job_path__ through unchanged" {
    _knit_metadata_store --key "__job_path__" --value "/scratch/jobs"
    local out
    _knit_job_root out
    [ "${out}" = "/scratch/jobs" ]
}

@test "job root falls back to jobs when __job_path__ is unset" {
    local out
    _knit_job_root out
    [ "${out}" = "${_KNIT_TEST_TMPDIR}/jobs" ]
}

# ---------- verbatim storage (metadata round-trip) ----------

@test "an absolute root is stored verbatim, not pre-resolved" {
    _knit_metadata_store --key "__job_path__" --value "/scratch/jobs"
    local raw
    _knit_metadata_get raw "__job_path__"
    [ "${raw}" = "/scratch/jobs" ]
}

# ---------- _knit_validate_instance_name ----------

@test "instance name validation accepts letters, digits, dot, underscore, hyphen" {
    _knit_validate_instance_name "my.env_1-name"
}

@test "instance name validation rejects a slash" {
    run _knit_validate_instance_name "a/b"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Invalid name"* ]]
}

@test "instance name validation rejects an empty name" {
    run _knit_validate_instance_name ""
    [ "${status}" -ne 0 ]
}

@test "instance name validation rejects spaces" {
    run _knit_validate_instance_name "my env"
    [ "${status}" -ne 0 ]
}

# ---------- _knit_bootstrap_warn_absolute_root ----------

@test "absolute-root warning fires for an absolute value" {
    run _knit_bootstrap_warn_absolute_root "--setup-path" "/scratch/setups"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"harder to reproduce"* ]]
}

@test "absolute-root warning is silent for a relative value" {
    run _knit_bootstrap_warn_absolute_root "--setup-path" "setups"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}
