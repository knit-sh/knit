#!/usr/bin/env bats

# Tests for the environment-manager registration API (src/env.sh), M1: the
# registration block, the registry, validation, bootstrap option declaration,
# and the body-driven provisioning dispatcher + lazy provisioner. Exercised with
# a "fake" manager whose verbs are shell stubs, so no real tool or network is
# involved.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    # Use a throwaway prefix so tests that create .knit/<name> never touch the
    # repository's real .knit.
    _KNIT_PREFIX="${BATS_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
}

teardown() {
    knit_test_db_teardown
}

# A fake manager whose verbs are trivial stubs. `provision` records its argv into
# a marker file so tests can assert what it was called with.
_register_fake() {
    local options="${1:-}"
    _fake_provision() { printf '%s\n' "$*" > "${_FAKE_PROVISION_LOG}"; }
    _fake_install()   { :; }
    _fake_activate()  { printf 'export FAKE=1\n'; }
    _fake_specs()     { printf 'fake-manifest\n'; }
    knit_register_env_manager "fake" "A fake manager."
    if [[ -n "${options}" ]]; then
        knit_env_provision _fake_provision --options "${options}"
    else
        knit_env_provision _fake_provision
    fi
    knit_env_install  _fake_install
    knit_env_activate _fake_activate
    knit_env_specs    _fake_specs
    knit_env_manifest "fake.yaml"
    knit_env_lockfile "fake.lock"
    knit_env_done
}

# ---------- registration + registry ----------

@test "a registered manager lands in the registry with all fields set" {
    _register_fake
    _knit_env_is_registered "fake"
    [ "$(declare -p _KNIT_ENV_MANAGERS)" ]
    [[ " ${_KNIT_ENV_MANAGERS[*]} " == *" fake "* ]]
    [ "${_KNIT_ENV_fake_display}" = "fake" ]
    [ "${_KNIT_ENV_fake_provision}" = "_fake_provision" ]
    [ "${_KNIT_ENV_fake_install}" = "_fake_install" ]
    [ "${_KNIT_ENV_fake_activate}" = "_fake_activate" ]
    [ "${_KNIT_ENV_fake_specs}" = "_fake_specs" ]
    [ "${_KNIT_ENV_fake_manifest}" = "fake.yaml" ]
    [ "${_KNIT_ENV_fake_lockfile}" = "fake.lock" ]
    # The registration context is cleared after knit_env_done.
    [ ! -v _KNIT_ENV_CURRENT ]
}

@test "registering the same manager twice is fatal" {
    _register_fake
    run _register_fake
    [ "$status" -ne 0 ]
    [[ "$output" == *"already registered"* ]]
}

@test "an invalid manager name is fatal" {
    run knit_register_env_manager "bad name" "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid environment-manager name"* ]]
}

@test "a knit_env_* setter outside a registration is fatal" {
    run knit_env_install _x
    [ "$status" -ne 0 ]
    [[ "$output" == *"between knit_register_env_manager and knit_env_done"* ]]
}

# ---------- validation at knit_env_done ----------

@test "knit_env_done is fatal when a verb is missing" {
    _incomplete() {
        _p() { :; }
        knit_register_env_manager "incomplete" "x"
        knit_env_provision _p
        knit_env_install _p
        # no activate / specs
        knit_env_manifest "m"
        knit_env_lockfile "l"
        knit_env_done
    }
    run _incomplete
    [ "$status" -ne 0 ]
    [[ "$output" == *"incomplete"* ]]
    [[ "$output" == *"activate"* ]]
    [[ "$output" == *"specs"* ]]
}

@test "knit_env_done is fatal when a scalar is missing" {
    _incomplete() {
        _p() { :; }
        knit_register_env_manager "nolock" "x"
        knit_env_provision _p
        knit_env_install _p
        knit_env_activate _p
        knit_env_specs _p
        knit_env_manifest "m"
        # no lockfile
        knit_env_done
    }
    run _incomplete
    [ "$status" -ne 0 ]
    [[ "$output" == *"lockfile"* ]]
}

# ---------- --options parsing + bootstrap declaration ----------

@test "declared options become optional bootstrap parameters" {
    _register_fake "ver:string"
    # The option is now a declared optional of the bootstrap command.
    local bcmd
    _knit_command_mangle bcmd "bootstrap"
    _knit_set_find "_KNIT_CMD_${bcmd}_optional" "ver"
}

@test "a two-option list parses in declared order" {
    _register_fake "one:string,two:string"
    local names=()
    _knit_env_option_names names "fake"
    [ "${#names[@]}" -eq 2 ]
    [ "${names[0]}" = "one" ]
    [ "${names[1]}" = "two" ]
}

@test "options with surrounding whitespace are trimmed" {
    _register_fake "one:string, two:string"
    local names=()
    _knit_env_option_names names "fake"
    [ "${#names[@]}" -eq 2 ]
    [ "${names[1]}" = "two" ]
}

@test "a manager with no options declares no bootstrap option and still provisions when required" {
    _register_fake
    local names=()
    _knit_env_option_names names "fake"
    [ "${#names[@]}" -eq 0 ]
    _KNIT_ENV_fake_required="1"
    _knit_env_need_provision "fake"
}

# ---------- need-provision logic ----------

@test "need-provision is true for a non-empty ref, false otherwise" {
    _register_fake "ver:string"
    _knit_env_need_provision "fake" "1.0"
    ! _knit_env_need_provision "fake" ""
}

@test "need-provision is true when the manager is flagged required" {
    _register_fake "ver:string"
    ! _knit_env_need_provision "fake" ""
    _KNIT_ENV_fake_required="1"
    _knit_env_need_provision "fake" ""
}

# ---------- body-driven provisioning dispatcher ----------

@test "provision is forwarded the option values positionally in declared order" {
    _FAKE_PROVISION_LOG="${BATS_TEST_TMPDIR}/prov.log"
    _register_fake "one:string,two:string"
    _knit_env_provision_all --one A --two B
    [ "$(cat "${_FAKE_PROVISION_LOG}")" = "A B" ]
}

@test "provision_all is a no-op when nothing is needed" {
    _FAKE_PROVISION_LOG="${BATS_TEST_TMPDIR}/prov.log"
    _register_fake "one:string"
    _knit_env_provision_all   # no --one, not required
    [ ! -f "${_FAKE_PROVISION_LOG}" ]
}

@test "provision_all runs a required manager even with empty refs" {
    _FAKE_PROVISION_LOG="${BATS_TEST_TMPDIR}/prov.log"
    _register_fake "one:string"
    _KNIT_ENV_fake_required="1"
    _knit_env_provision_all   # no --one, but required
    [ -f "${_FAKE_PROVISION_LOG}" ]
    [ "$(cat "${_FAKE_PROVISION_LOG}")" = "" ]
}

# ---------- lazy provisioner ----------

@test "ensure_provisioned calls provision with empty refs when absent" {
    _FAKE_PROVISION_LOG="${BATS_TEST_TMPDIR}/prov.log"
    _register_fake "one:string,two:string"
    _KNIT_IS_BOOTSTRAPPED="1"
    # .knit/fake absent -> provision with two empty refs.
    knit_env_ensure_provisioned "fake"
    [ -f "${_FAKE_PROVISION_LOG}" ]
    [ "$(cat "${_FAKE_PROVISION_LOG}")" = " " ]
}

@test "ensure_provisioned is a no-op when the tool is already present" {
    _FAKE_PROVISION_LOG="${BATS_TEST_TMPDIR}/prov.log"
    _register_fake
    _KNIT_IS_BOOTSTRAPPED="1"
    mkdir -p "${_KNIT_PREFIX}/fake"
    knit_env_ensure_provisioned "fake"
    [ ! -f "${_FAKE_PROVISION_LOG}" ]
}

@test "ensure_provisioned is fatal for an unknown manager" {
    run knit_env_ensure_provisioned "nope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown environment manager"* ]]
}

# ---------- manager-specific install options channel ----------

# knit_env_record_option self-guards the setup context, so these tests simulate
# an open setup registration (the state knit_register_setup leaves behind).
_in_setup_context() {
    _KNIT_CURRENT_COMMAND="setup__1__demo"
    _KNIT_CURRENT_COMMAND_DEMANGLED="setup:demo"
}

@test "recording an option creates the list and appends in declared order" {
    _register_fake
    _in_setup_context
    knit_env_record_option "fake" "layered"
    knit_env_record_option "fake" "no-deps"
    # shellcheck disable=SC2178 # nameref to the per-command options array
    local -n opts="_KNIT_CMD_setup__1__demo_envopts_fake"
    [ "${#opts[@]}" -eq 2 ]
    [ "${opts[0]}" = "layered" ]
    [ "${opts[1]}" = "no-deps" ]
}

@test "options are recorded only under the named manager" {
    _register_fake
    _in_setup_context
    knit_env_record_option "fake" "layered"
    [ "$(declare -p _KNIT_CMD_setup__1__demo_envopts_fake 2>/dev/null)" ]
    ! declare -p _KNIT_CMD_setup__1__demo_envopts_other 2>/dev/null
}

@test "recording an option for an unknown manager is fatal" {
    _in_setup_context
    run knit_env_record_option "nope" "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown environment manager"* ]]
}

@test "recording an option outside a setup registration is fatal" {
    _register_fake
    unset _KNIT_CURRENT_COMMAND _KNIT_CURRENT_COMMAND_DEMANGLED
    run knit_env_record_option "fake" "layered"
    [ "$status" -ne 0 ]
    [[ "$output" == *"setup registration"* ]]
}

@test "the install verb receives the recorded options as trailing args in order" {
    _FAKE_INSTALL_LOG="${BATS_TEST_TMPDIR}/install.log"
    _register_fake
    _in_setup_context
    knit_env_record_option "fake" "layered"
    knit_env_record_option "fake" "no-deps"

    # Drive the before-callback with the orthogonal steps (platform sourcing,
    # manifest resolution) stubbed out so this isolates the option forwarding.
    _KNIT_INVOCATION_CMD="setup__1__demo"
    KNIT_SETUP_PREFIX="${BATS_TEST_TMPDIR}/setup"
    mkdir -p "${KNIT_SETUP_PREFIX}" "${_KNIT_PREFIX}/fake"
    _knit_setup_source_platform() { :; }
    # shellcheck disable=SC2178 # scalar nameref output
    _knit_env_resolve_manifest() { local -n r=$1; r="fake-manifest"; }
    _fake_install() { printf '%s\n' "$*" > "${_FAKE_INSTALL_LOG}"; }

    _knit_env_setup_before_cb "fake"

    # argv is <env_dir> <manifest_path> layered no-deps.
    [[ "$(cat "${_FAKE_INSTALL_LOG}")" == *" layered no-deps" ]]
}

@test "the install verb receives no trailing option args when none are recorded" {
    _FAKE_INSTALL_LOG="${BATS_TEST_TMPDIR}/install.log"
    _register_fake
    _KNIT_INVOCATION_CMD="setup__1__demo"
    KNIT_SETUP_PREFIX="${BATS_TEST_TMPDIR}/setup"
    mkdir -p "${KNIT_SETUP_PREFIX}" "${_KNIT_PREFIX}/fake"
    _knit_setup_source_platform() { :; }
    # shellcheck disable=SC2178 # scalar nameref output
    _knit_env_resolve_manifest() { local -n r=$1; r="fake-manifest"; }
    # Record argc: only <env_dir> + <manifest_path>, no option args.
    _fake_install() { printf '%s\n' "$#" > "${_FAKE_INSTALL_LOG}"; }

    _knit_env_setup_before_cb "fake"

    [ "$(cat "${_FAKE_INSTALL_LOG}")" = "2" ]
}
