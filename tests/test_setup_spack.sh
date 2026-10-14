#!/usr/bin/env bats

# Spack-specific tests of the environment-manager integration: that Spack is
# registered as a manager (so knit_with_spack_env / knit_with_spack_specs are
# generated and a Spack setup declares the __spack_manifest__ / __spack_lock__
# columns), and that the Spack verbs (_knit_spack_activation,
# _knit_spack_specs_to_manifest) produce the expected output. The generic
# directive/callback behaviour is covered by test_env_setup.sh.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    # Point the Spack root at an existing directory so a setup before-callback's
    # on-demand provisioning would be a no-op.
    _KNIT_SPACK_ROOT="${_KNIT_PREFIX}/spack"
    mkdir -p "${_KNIT_SPACK_ROOT}"
    _test_setup_fn() { :; }
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    unset KNIT_SETUP_PREFIX
    knit_test_db_teardown
}

# ---------- Spack is registered as an environment manager ----------

@test "Spack is registered as an environment manager" {
    _knit_env_is_registered "spack"
    [ "${_KNIT_ENV_spack_manifest}" = "spack.yaml" ]
    [ "${_KNIT_ENV_spack_lockfile}" = "spack.lock" ]
}

@test "the spack setup directives are generated" {
    declare -F knit_with_spack_env
    declare -F knit_with_spack_specs
}

@test "the spack setup shorthands are generated" {
    # Spack is a core manager (src/spack.sh loads before src/shorthand.sh), so
    # its shorthands come from the source-time generator, not knit_env_done.
    declare -F @with_spack_env
    declare -F @with_spack_specs
}

@test "a Spack setup declares __spack_manifest__ and __spack_lock__ columns" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env "spack.yaml"
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('setup:libs');" \
        | cut -d'|' -f2 | tr '\n' ',')
    [[ "${names}" == *__spack_manifest__* ]]
    [[ "${names}" == *__spack_lock__* ]]
}

@test "knit_with_spack_env flags the spack manager required" {
    _KNIT_ENV_spack_required=""
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env "spack.yaml"
    knit_done
    [ -n "${_KNIT_ENV_spack_required}" ]
}

@test "knit_with_spack_env records a --help note mentioning spack" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env "spack.yaml"
    knit_done
    local result
    result=$(_knit_invoke_command "setup" "libs" "--help")
    [[ "${result}" == *"spack environment"* ]]
}

# ---------- Spack verbs ----------

@test "_knit_spack_activation prints source + env activate for the env dir" {
    _KNIT_SPACK_ROOT="/fake/spack"
    run _knit_spack_activation "/some/env-dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"source /fake/spack/share/spack/setup-env.sh"* ]]
    [[ "$output" == *"spack env activate -d /some/env-dir"* ]]
}

@test "_knit_spack_specs_to_manifest synthesizes a spack.yaml with the given specs" {
    run _knit_spack_specs_to_manifest "hdf5@1.14" "fftw"
    [ "$status" -eq 0 ]
    [[ "$output" == *"spack:"* ]]
    [[ "$output" == *"specs:"* ]]
    [[ "$output" == *"- hdf5@1.14"* ]]
    [[ "$output" == *"- fftw"* ]]
    [[ "$output" == *"view: true"* ]]
}

# ---------- Spack setup end-to-end (generic callback + Spack verbs) ----------

@test "a Spack setup's after callback appends the spack re-activation to .activate.sh" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}/spack-env"
    printf 'export ORIG=1\n' > "${KNIT_SETUP_PREFIX}/.activate.sh"
    _KNIT_SPACK_ROOT="/fake/spack"
    _knit_env_setup_after_cb "spack"
    grep -q "ORIG=1" "${KNIT_SETUP_PREFIX}/.activate.sh"
    grep -q "setup-env.sh" "${KNIT_SETUP_PREFIX}/.activate.sh"
    grep -q "spack env activate -d" "${KNIT_SETUP_PREFIX}/.activate.sh"
}

@test "a Spack setup's after callback captures spack.yaml/spack.lock provenance" {
    command -v gzip >/dev/null 2>&1 || skip "gzip not available"
    command -v base64 >/dev/null 2>&1 || skip "base64 not available"
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env "spack.yaml"
    knit_done
    local cmd
    _knit_command_mangle cmd "setup:libs"
    declare -gA "_KNIT_CMD_${cmd}_output_value=()"
    _KNIT_EXECUTING_COMMAND=("${cmd}")

    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    local env_dir="${KNIT_SETUP_PREFIX}/spack-env"
    mkdir -p "${env_dir}"
    printf 'MANIFEST' > "${env_dir}/spack.yaml"
    printf 'LOCKDATA' > "${env_dir}/spack.lock"
    touch "${KNIT_SETUP_PREFIX}/.activate.sh"
    _KNIT_SPACK_ROOT="/fake/spack"
    _knit_env_setup_after_cb "spack"

    local -n _out_ref="_KNIT_CMD_${cmd}_output_value"
    [ "$(printf '%s' "${_out_ref[__spack_manifest__]}" | base64 -d | gunzip)" = "MANIFEST" ]
    [ "$(printf '%s' "${_out_ref[__spack_lock__]}" | base64 -d | gunzip)" = "LOCKDATA" ]
}
