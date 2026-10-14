#!/usr/bin/env bats

# Tests for the M2 generated setup directives of the environment-manager layer:
# knit_with_<nm>_env / knit_with_<nm>_specs and their build/activate/provenance
# callbacks (_knit_env_setup_before_cb / _knit_env_setup_after_cb). Exercised
# with a "fake" manager whose verbs are shell stubs.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    # Pre-create the tool dir so the before-callback's on-demand provisioning is
    # a no-op by default (the "provisions when absent" test removes it).
    mkdir -p "${_KNIT_PREFIX}/fake"

    _test_setup_fn() { :; }

    # The fake manager's verbs (overridable per test).
    _fake_provision() { mkdir -p "${_KNIT_PREFIX}/fake"; printf 'provisioned\n' > "${_FAKE_PROVISION_LOG:-/dev/null}"; }
    _fake_install() {
        local env_dir="$1" manifest="$2"
        mkdir -p "${env_dir}"
        cp "${manifest}" "${env_dir}/fake.yaml"
        printf 'LOCKDATA\n' > "${env_dir}/fake.lock"
    }
    _fake_activate() { printf 'export FAKE_ENV=%q\n' "$1"; }
    _fake_specs() {
        printf 'fake:\n  specs:\n'
        local s
        for s in "$@"; do printf '    - %s\n' "${s}"; done
    }

    knit_register_env_manager "fake" "A fake manager."
    knit_env_provision _fake_provision
    knit_env_install   _fake_install
    knit_env_activate  _fake_activate
    knit_env_specs     _fake_specs
    knit_env_manifest  "fake.yaml"
    knit_env_lockfile  "fake.lock"
    knit_env_done
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    unset KNIT_SETUP_PREFIX
    knit_test_db_teardown
}

# ---------- knit_with_<nm>_env: registration ----------

@test "the env/specs directive functions are generated" {
    declare -F knit_with_fake_env
    declare -F knit_with_fake_specs
}

@test "the env/specs shorthands are generated for a late-registered manager" {
    # The fake manager is registered in setup(), after knit.sh is sourced, so
    # knit_env_done takes the plugin path and registers the shorthands directly.
    declare -F @with_fake_env
    declare -F @with_fake_specs
}

@test "the env shorthand forwards to its directive" {
    knit_with_fake_env() { printf 'env:%s' "$*"; }
    run @with_fake_env "x.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "env:x.yaml" ]
}

@test "knit_with_fake_env flags the manager required" {
    _KNIT_ENV_fake_required=""
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_fake_env "fake.yaml"
    knit_done
    [ -n "${_KNIT_ENV_fake_required}" ]
}

@test "knit_with_fake_env path form resolves to an absolute path in the before callback" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_fake_env "fake.yaml"
    knit_done
    local cmd cbs
    _knit_command_mangle cmd "setup:libs"
    eval "cbs=\"\${_KNIT_CMD_${cmd}_before_cb[*]}\""
    [[ "${cbs}" == *_knit_env_setup_before_cb* ]]
    [[ "${cbs}" == *fake* ]]
    [[ "${cbs}" == *file* ]]
    [[ "${cbs}" == */fake.yaml* ]]
}

@test "knit_with_fake_env stdin form captures the manifest content" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_fake_env <<'EOF'
fake:
  specs:
    - zlib
EOF
    knit_done
    local cmd cbs
    _knit_command_mangle cmd "setup:libs"
    eval "cbs=\"\${_KNIT_CMD_${cmd}_before_cb[*]}\""
    [[ "${cbs}" == *stdin* ]]
    [[ "${cbs}" == *zlib* ]]
}

@test "knit_with_fake_env declares __fake_manifest__ and __fake_lock__ columns" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_fake_env "fake.yaml"
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('setup:libs');" \
        | cut -d'|' -f2 | tr '\n' ',')
    [[ "${names}" == *__fake_manifest__* ]]
    [[ "${names}" == *__fake_lock__* ]]
}

@test "a setup without the directive has no __fake_*__ columns" {
    knit_register_setup "plain" "_test_setup_fn" "Plain setup."
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('setup:plain');" \
        | cut -d'|' -f2 | tr '\n' ',')
    [[ "${names}" != *__fake_manifest__* ]]
    [[ "${names}" != *__fake_lock__* ]]
}

@test "knit_with_fake_env records a --help note" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_fake_env "fake.yaml"
    knit_done
    local result
    result=$(_knit_invoke_command "setup" "libs" "--help")
    [[ "${result}" == *"fake environment"* ]]
}

@test "knit_with_fake_env installs the env after callback last" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_fake_env "fake.yaml"
    knit_done
    local cmd
    _knit_command_mangle cmd "setup:libs"
    local -a cbs
    eval "cbs=(\"\${_KNIT_CMD_${cmd}_after_cb[@]}\")"
    [[ "${cbs[0]}" == *_knit_setup_after_cb* ]]
    [[ "${cbs[-1]}" == *_knit_env_setup_after_cb* ]]
}

# ---------- knit_with_<nm>_env: validation ----------

@test "knit_with_fake_env is fatal outside a setup registration" {
    run knit_with_fake_env "fake.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"only for setups"* ]]
}

@test "knit_with_fake_env is fatal when declared twice" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_fake_env "a.yaml"
    run knit_with_fake_env "b.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at most one"* ]]
}

@test "knit_with_fake_env is fatal (does not hang) with no manifest on a terminal" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    _knit_stdin_is_terminal() { return 0; }
    run knit_with_fake_env
    [ "$status" -ne 0 ]
    [[ "$output" == *"no manifest provided"* ]]
}

@test "knit_with_fake_env is fatal when the stdin manifest is empty" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    run knit_with_fake_env < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]
}

# ---------- knit_with_<nm>_specs ----------

@test "knit_with_fake_specs synthesizes a manifest with the given specs" {
    _KNIT_CURRENT_COMMAND="setup__1__libs"
    _KNIT_CURRENT_COMMAND_DEMANGLED="setup:libs"
    # The sugar funnels through the generic _knit_env_with_env via stdin; capture
    # what it feeds there.
    _knit_env_with_env() { cat > "${_KNIT_TEST_TMPDIR}/captured.yaml"; }
    knit_with_fake_specs "hdf5@1.14" "fftw"
    grep -q "^fake:" "${_KNIT_TEST_TMPDIR}/captured.yaml"
    grep -q -- "- hdf5@1.14" "${_KNIT_TEST_TMPDIR}/captured.yaml"
    grep -q -- "- fftw" "${_KNIT_TEST_TMPDIR}/captured.yaml"
}

@test "knit_with_fake_specs is fatal with no specs" {
    _KNIT_CURRENT_COMMAND="setup__1__libs"
    _KNIT_CURRENT_COMMAND_DEMANGLED="setup:libs"
    run knit_with_fake_specs
    [ "$status" -ne 0 ]
}

@test "knit_with_fake_specs is fatal outside a setup registration" {
    run knit_with_fake_specs "zlib"
    [ "$status" -ne 0 ]
    [[ "$output" == *"only for setups"* ]]
}

@test "knit_with_fake_specs and knit_with_fake_env are mutually exclusive" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_fake_specs "zlib"
    run knit_with_fake_env "a.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at most one"* ]]
}

# ---------- _knit_env_setup_before_cb ----------

@test "before callback materializes the stdin manifest, builds, and activates in-shell" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}"
    FAKE_ENV=""
    _knit_env_setup_before_cb "fake" "stdin" $'fake:\n  specs:\n    - zlib'
    [ -f "${KNIT_SETUP_PREFIX}/fake.yaml" ]
    grep -q "zlib" "${KNIT_SETUP_PREFIX}/fake.yaml"
    [ -d "${KNIT_SETUP_PREFIX}/fake-env" ]
    # Activation ran in the current shell.
    [ "${FAKE_ENV}" = "${KNIT_SETUP_PREFIX}/fake-env" ]
}

@test "before callback copies the file-form manifest" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}"
    printf 'fake: {}\n' > "${_KNIT_TEST_TMPDIR}/src.yaml"
    _knit_env_setup_before_cb "fake" "file" "${_KNIT_TEST_TMPDIR}/src.yaml"
    [ -f "${KNIT_SETUP_PREFIX}/fake.yaml" ]
    grep -q "fake: {}" "${KNIT_SETUP_PREFIX}/fake.yaml"
}

@test "before callback calls install with the env dir and manifest path" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}"
    _fake_install() { printf '%s' "$*" > "${_KNIT_TEST_TMPDIR}/install.args"; }
    _knit_env_setup_before_cb "fake" "stdin" "fake: {}"
    run cat "${_KNIT_TEST_TMPDIR}/install.args"
    [[ "$output" == *"${KNIT_SETUP_PREFIX}/fake-env ${KNIT_SETUP_PREFIX}/fake.yaml"* ]]
}

@test "before callback sources the platform fragment before activating" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}" "${_KNIT_PREFIX}"
    printf '%s\n' 'export _KNIT_TEST_ENV_PLATFORM=on' > "${_KNIT_PREFIX}/platform.sh"
    _knit_env_setup_before_cb "fake" "stdin" "fake: {}"
    [ "${_KNIT_TEST_ENV_PLATFORM:-}" = "on" ]
    unset _KNIT_TEST_ENV_PLATFORM
}

@test "before callback provisions on demand when the tool is absent" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}"
    _FAKE_PROVISION_LOG="${_KNIT_TEST_TMPDIR}/prov.log"
    _KNIT_IS_BOOTSTRAPPED="1"
    rm -rf "${_KNIT_PREFIX}/fake"   # tool absent -> ensure provisions it
    _knit_env_setup_before_cb "fake" "stdin" "fake: {}"
    [ -f "${_FAKE_PROVISION_LOG}" ]
}

@test "before callback returns non-zero and does not activate when install fails" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}"
    _fake_install() { return 1; }
    FAKE_ENV=""
    ! _knit_env_setup_before_cb "fake" "stdin" "fake: {}"
    [ -z "${FAKE_ENV}" ]
}

# ---------- _knit_env_setup_after_cb ----------

@test "after callback appends the re-activation block to .activate.sh" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}/fake-env"
    printf 'export ORIG=1\n' > "${KNIT_SETUP_PREFIX}/.activate.sh"
    _knit_env_setup_after_cb "fake"
    grep -q "ORIG=1" "${KNIT_SETUP_PREFIX}/.activate.sh"
    grep -q "FAKE_ENV=" "${KNIT_SETUP_PREFIX}/.activate.sh"
    grep -q "re-activation" "${KNIT_SETUP_PREFIX}/.activate.sh"
}

@test "after callback captures manifest and lock provenance (round-trip)" {
    command -v gzip >/dev/null 2>&1 || skip "gzip not available"
    command -v base64 >/dev/null 2>&1 || skip "base64 not available"
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_fake_env "fake.yaml"
    knit_done
    local cmd
    _knit_command_mangle cmd "setup:libs"
    declare -gA "_KNIT_CMD_${cmd}_output_value=()"
    _KNIT_EXECUTING_COMMAND=("${cmd}")

    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    local env_dir="${KNIT_SETUP_PREFIX}/fake-env"
    mkdir -p "${env_dir}"
    printf 'MANIFEST' > "${env_dir}/fake.yaml"
    printf 'LOCKDATA' > "${env_dir}/fake.lock"
    touch "${KNIT_SETUP_PREFIX}/.activate.sh"
    _knit_env_setup_after_cb "fake"

    local -n _out_ref="_KNIT_CMD_${cmd}_output_value"
    [ -n "${_out_ref[__fake_manifest__]}" ]
    [ -n "${_out_ref[__fake_lock__]}" ]
    [ "$(printf '%s' "${_out_ref[__fake_manifest__]}" | base64 -d | gunzip)" = "MANIFEST" ]
    [ "$(printf '%s' "${_out_ref[__fake_lock__]}" | base64 -d | gunzip)" = "LOCKDATA" ]
}

@test "after callback records no provenance when the env files are absent" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_fake_env "fake.yaml"
    knit_done
    local cmd
    _knit_command_mangle cmd "setup:libs"
    declare -gA "_KNIT_CMD_${cmd}_output_value=()"

    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}/fake-env"
    touch "${KNIT_SETUP_PREFIX}/.activate.sh"
    _knit_env_setup_after_cb "fake"

    local -n _out_ref="_KNIT_CMD_${cmd}_output_value"
    [ -z "${_out_ref[__fake_manifest__]:-}" ]
    [ -z "${_out_ref[__fake_lock__]:-}" ]
}
