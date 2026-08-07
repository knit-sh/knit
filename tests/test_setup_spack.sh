#!/usr/bin/env bats

# Tests for the M4 setup Spack-environment directives: knit_with_spack_env,
# knit_with_spack_specs, and their build/activation callbacks.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_SPACK_REQUIRED=""
    # Point the Spack root at an existing directory so the before-callback's
    # on-demand provisioning is a no-op (these tests exercise the callback, not
    # provisioning; see test_spack.sh for _knit_spack_ensure_provisioned).
    _KNIT_SPACK_ROOT="${_KNIT_TEST_TMPDIR}/spack"
    mkdir -p "${_KNIT_SPACK_ROOT}"
    _test_setup_fn() { :; }
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    unset KNIT_SETUP_PREFIX
    _KNIT_SPACK_REQUIRED=""
    knit_test_db_teardown
}

# ---------- knit_with_spack_env: registration ----------

@test "knit_with_spack_env sets _KNIT_SPACK_REQUIRED" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env "spack.yaml"
    knit_done
    [ -n "${_KNIT_SPACK_REQUIRED}" ]
}

@test "knit_with_spack_env path form resolves to an absolute path in the before callback" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env "spack.yaml"
    knit_done
    local cmd cbs
    cmd=$(_knit_command_mangle "setup:libs")
    eval "cbs=\"\${_KNIT_CMD_${cmd}_before_cb[*]}\""
    [[ "${cbs}" == *_knit_setup_spack_env_before_cb* ]]
    [[ "${cbs}" == *file* ]]
    # An absolute path starts with "/"; the resolved spack.yaml must appear.
    [[ "${cbs}" == */spack.yaml* ]]
}

@test "knit_with_spack_env stdin form captures the manifest content" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env <<'EOF'
spack:
  specs:
    - zlib
EOF
    knit_done
    local cmd cbs
    cmd=$(_knit_command_mangle "setup:libs")
    eval "cbs=\"\${_KNIT_CMD_${cmd}_before_cb[*]}\""
    [[ "${cbs}" == *stdin* ]]
    [[ "${cbs}" == *zlib* ]]
}

@test "knit_with_spack_env declares __spack_yaml__ and __spack_lock__ columns" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env "spack.yaml"
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('setup:libs');" \
        | cut -d'|' -f2 | tr '\n' ',')
    [[ "${names}" == *__spack_yaml__* ]]
    [[ "${names}" == *__spack_lock__* ]]
}

@test "a setup without the directive has no __spack_*__ columns" {
    knit_register_setup "plain" "_test_setup_fn" "Plain setup."
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('setup:plain');" \
        | cut -d'|' -f2 | tr '\n' ',')
    [[ "${names}" != *__spack_yaml__* ]]
    [[ "${names}" != *__spack_lock__* ]]
}

@test "knit_with_spack_env records a --help note" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env "spack.yaml"
    knit_done
    local result
    result=$(_knit_invoke_command "setup" "libs" "--help")
    [[ "${result}" == *"Spack environment"* ]]
}

@test "knit_with_spack_env installs the spack after callback last" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env "spack.yaml"
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "setup:libs")
    local -a cbs
    eval "cbs=(\"\${_KNIT_CMD_${cmd}_after_cb[@]}\")"
    # The generic dump must come first (it truncates .activate.sh), the spack
    # re-activation block last (it appends and is authoritative).
    [[ "${cbs[0]}" == *_knit_setup_after_cb* ]]
    [[ "${cbs[-1]}" == *_knit_setup_spack_env_after_cb* ]]
}

# ---------- knit_with_spack_env: validation ----------

@test "knit_with_spack_env is fatal outside a setup registration" {
    run knit_with_spack_env "spack.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"only for setups"* ]]
}

@test "knit_with_spack_env is fatal when declared twice" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env "a.yaml"
    run knit_with_spack_env "b.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at most one"* ]]
}

@test "_knit_stdin_is_terminal reports non-terminal stdin under redirection" {
    # Under bats stdin is redirected, so the helper must report false.
    run _knit_stdin_is_terminal < /dev/null
    [ "$status" -ne 0 ]
}

@test "knit_with_spack_env is fatal (does not hang) when no manifest is given on a terminal" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    # Simulate an interactive terminal so the directive must fail fast instead of
    # blocking on "cat" waiting for input that will never arrive.
    _knit_stdin_is_terminal() { return 0; }
    run knit_with_spack_env
    [ "$status" -ne 0 ]
    [[ "$output" == *"no manifest provided"* ]]
}

@test "knit_with_spack_env is fatal when the stdin manifest is empty" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    run knit_with_spack_env < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]
}

# ---------- knit_with_spack_specs ----------

@test "knit_with_spack_specs synthesizes a spack.yaml with the given specs" {
    _KNIT_CURRENT_COMMAND="setup__1__libs"
    _KNIT_CURRENT_COMMAND_DEMANGLED="setup:libs"
    # Capture what the sugar feeds to knit_with_spack_env via stdin.
    knit_with_spack_env() { cat > "${_KNIT_TEST_TMPDIR}/captured.yaml"; }
    knit_with_spack_specs "hdf5@1.14" "fftw"
    grep -q "^spack:" "${_KNIT_TEST_TMPDIR}/captured.yaml"
    grep -q "specs:" "${_KNIT_TEST_TMPDIR}/captured.yaml"
    grep -q -- "- hdf5@1.14" "${_KNIT_TEST_TMPDIR}/captured.yaml"
    grep -q -- "- fftw" "${_KNIT_TEST_TMPDIR}/captured.yaml"
    grep -q "view: true" "${_KNIT_TEST_TMPDIR}/captured.yaml"
}

@test "knit_with_spack_specs is fatal with no specs" {
    _KNIT_CURRENT_COMMAND="setup__1__libs"
    _KNIT_CURRENT_COMMAND_DEMANGLED="setup:libs"
    run knit_with_spack_specs
    [ "$status" -ne 0 ]
}

@test "knit_with_spack_specs is fatal outside a setup registration" {
    run knit_with_spack_specs "zlib"
    [ "$status" -ne 0 ]
    [[ "$output" == *"only for setups"* ]]
}

@test "knit_with_spack_specs and knit_with_spack_env are mutually exclusive" {
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_specs "zlib"
    run knit_with_spack_env "a.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at most one"* ]]
}

# ---------- _knit_setup_spack_env_before_cb ----------

@test "before callback materializes the stdin manifest to spack.yaml" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}"
    _knit_spack_env_install() { :; }
    _knit_spack_exec() { printf '%s\n' "$*" >> "${_KNIT_TEST_TMPDIR}/exec.log"; }
    _knit_setup_spack_env_before_cb "stdin" $'spack:\n  specs:\n    - zlib'
    [ -f "${KNIT_SETUP_PREFIX}/spack.yaml" ]
    grep -q "zlib" "${KNIT_SETUP_PREFIX}/spack.yaml"
    grep -q "env activate -d" "${_KNIT_TEST_TMPDIR}/exec.log"
}

@test "before callback copies the file-form manifest to spack.yaml" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}"
    printf 'spack: {}\n' > "${_KNIT_TEST_TMPDIR}/src.yaml"
    _knit_spack_env_install() { :; }
    _knit_spack_exec() { :; }
    _knit_setup_spack_env_before_cb "file" "${_KNIT_TEST_TMPDIR}/src.yaml"
    [ -f "${KNIT_SETUP_PREFIX}/spack.yaml" ]
    grep -q "spack: {}" "${KNIT_SETUP_PREFIX}/spack.yaml"
}

@test "before callback calls _knit_spack_env_install with the env dir and yaml" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}"
    _knit_spack_env_install() { printf '%s' "$*" > "${_KNIT_TEST_TMPDIR}/install.args"; }
    _knit_spack_exec() { :; }
    _knit_setup_spack_env_before_cb "stdin" "spack: {}"
    run cat "${_KNIT_TEST_TMPDIR}/install.args"
    [[ "$output" == *"${KNIT_SETUP_PREFIX}/spack-env ${KNIT_SETUP_PREFIX}/spack.yaml"* ]]
}

@test "before callback sources the platform fragment before activating Spack" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    printf '%s\n' 'export _KNIT_TEST_SPACK_PLATFORM=on' > "${_KNIT_PREFIX}/platform.sh"
    _knit_spack_env_install() { :; }
    _knit_spack_exec() { :; }
    _knit_setup_spack_env_before_cb "stdin" "spack: {}"
    [ "${_KNIT_TEST_SPACK_PLATFORM:-}" = "on" ]
    unset _KNIT_TEST_SPACK_PLATFORM
}

@test "before callback returns non-zero and does not activate when the install fails" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}"
    _knit_spack_env_install() { return 1; }
    _knit_spack_exec() { printf '%s\n' "$*" >> "${_KNIT_TEST_TMPDIR}/exec.log"; }
    run _knit_setup_spack_env_before_cb "stdin" "spack: {}"
    [ "$status" -ne 0 ]
    # A failed environment install must not be activated.
    [ ! -f "${_KNIT_TEST_TMPDIR}/exec.log" ] \
        || ! grep -q "env activate -d" "${_KNIT_TEST_TMPDIR}/exec.log"
}

# ---------- _knit_setup_spack_env_after_cb ----------

@test "after callback appends the re-activation block to .activate.sh" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}/spack-env"
    printf 'export ORIG=1\n' > "${KNIT_SETUP_PREFIX}/.activate.sh"
    _KNIT_SPACK_ROOT="/fake/spack"
    _knit_setup_spack_env_after_cb
    # Original content preserved (block is appended, not overwritten).
    grep -q "ORIG=1" "${KNIT_SETUP_PREFIX}/.activate.sh"
    grep -q "setup-env.sh" "${KNIT_SETUP_PREFIX}/.activate.sh"
    grep -q "spack env activate -d" "${KNIT_SETUP_PREFIX}/.activate.sh"
}

@test "after callback captures spack.yaml and spack.lock provenance (round-trip)" {
    command -v gzip >/dev/null 2>&1 || skip "gzip not available"
    command -v base64 >/dev/null 2>&1 || skip "base64 not available"
    # The after-callback emits provenance with knit_output, which requires the
    # outputs to be declared and the command to be on the executing-command
    # stack (Option A keeps it there through the after-callbacks). Register a
    # real setup to declare the outputs, then simulate mid-invocation state.
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env "spack.yaml"
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "setup:libs")
    declare -gA "_KNIT_CMD_${cmd}_output_value=()"
    _KNIT_EXECUTING_COMMAND=("${cmd}")

    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    local env_dir="${KNIT_SETUP_PREFIX}/spack-env"
    mkdir -p "${env_dir}"
    printf 'MANIFEST' > "${env_dir}/spack.yaml"
    printf 'LOCKDATA' > "${env_dir}/spack.lock"
    touch "${KNIT_SETUP_PREFIX}/.activate.sh"
    _KNIT_SPACK_ROOT="/fake/spack"
    _knit_setup_spack_env_after_cb

    local -n _out_ref="_KNIT_CMD_${cmd}_output_value"
    local yaml_b64="${_out_ref[__spack_yaml__]}"
    local lock_b64="${_out_ref[__spack_lock__]}"
    [ -n "${yaml_b64}" ]
    [ -n "${lock_b64}" ]
    [ "$(printf '%s' "${yaml_b64}" | base64 -d | gunzip)" = "MANIFEST" ]
    [ "$(printf '%s' "${lock_b64}" | base64 -d | gunzip)" = "LOCKDATA" ]
}

@test "after callback records no provenance when the env files are absent" {
    # With no spack.yaml/spack.lock present, the after-callback makes no
    # knit_output calls, so no executing-command context is needed.
    knit_register_setup "libs" "_test_setup_fn" "Build deps."
    knit_with_spack_env "spack.yaml"
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "setup:libs")
    declare -gA "_KNIT_CMD_${cmd}_output_value=()"

    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}/spack-env"
    touch "${KNIT_SETUP_PREFIX}/.activate.sh"
    _KNIT_SPACK_ROOT="/fake/spack"
    _knit_setup_spack_env_after_cb

    local -n _out_ref="_KNIT_CMD_${cmd}_output_value"
    [ -z "${_out_ref[__spack_yaml__]:-}" ]
    [ -z "${_out_ref[__spack_lock__]:-}" ]
}
