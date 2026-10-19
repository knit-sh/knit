#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit

    # Each test controls _KNIT_PREFIX explicitly; point it at a temp path.
    __TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${__TEST_TMPDIR}/fake-knit"
}

teardown() {
    rm -rf "${__TEST_TMPDIR}"
}

# Marker written by the stubbed build (records the version/url it was built with).
__pilotd_build_marker=""
# File capturing the (stubbed) "knit metadata store" provenance calls.
__pilotd_meta=""

# Stub the network+compiler build and capture the metadata calls so the
# provisioning logic (version/url resolution, provenance recording) can be
# exercised without downloading or compiling anything.
_setup_pilotd_decision() {
    mkdir "${_KNIT_PREFIX}"
    _KNIT_PILOTD_EXE="${_KNIT_PREFIX}/knit-pilotd/bin/knit-pilotd"
    __pilotd_build_marker="${__TEST_TMPDIR}/pilotd-built"
    __pilotd_meta="${__TEST_TMPDIR}/pilotd-meta"
    : > "${__pilotd_meta}"
    eval '_knit_build_pilotd() { printf "%s\n" "$*" > "'"${__pilotd_build_marker}"'"; }'
    eval 'knit() { printf "%s\n" "$*" >> "'"${__pilotd_meta}"'"; }'
}

# ---------- _KNIT_PILOTD_EXE ----------

# _KNIT_PILOTD_EXE is frozen from _KNIT_PREFIX when the source is loaded, so the
# stable invariant is its install layout under a "knit-pilotd" prefix directory,
# not the exact prefix (which setup() resets only after sourcing).
@test "the knit-pilotd executable lives under a knit-pilotd prefix directory" {
    [[ "${_KNIT_PILOTD_EXE}" == */knit-pilotd/bin/knit-pilotd ]]
}

# ---------- _knit_pilotd_url ----------

@test "knit-pilotd url is derived from the version" {
    run _knit_pilotd_url "0.1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "https://github.com/knit-sh/knit-pilotd/releases/download/v0.1.0/knit-pilotd-0.1.0.tar.gz" ]
}

# ---------- _knit_bootstrap_pilotd ----------

@test "bootstrap knit-pilotd builds the pinned default version and records provenance" {
    _setup_pilotd_decision

    _knit_bootstrap_pilotd

    # Built with the pinned version and its derived url.
    grep -q "${_KNIT_PILOTD_VERSION}" "${__pilotd_build_marker}"
    grep -q "knit-pilotd-${_KNIT_PILOTD_VERSION}.tar.gz" "${__pilotd_build_marker}"
    # Provenance recorded (version + url).
    grep -q "metadata store --key __knit_pilotd_version__ --value ${_KNIT_PILOTD_VERSION}" "${__pilotd_meta}"
    grep -q "metadata store --key __knit_pilotd_url__ --value https://github.com/knit-sh/knit-pilotd/releases/download/v${_KNIT_PILOTD_VERSION}/knit-pilotd-${_KNIT_PILOTD_VERSION}.tar.gz" "${__pilotd_meta}"
}

@test "bootstrap knit-pilotd honours an explicit version" {
    _setup_pilotd_decision

    _knit_bootstrap_pilotd "9.9.9"

    grep -q "9.9.9" "${__pilotd_build_marker}"
    grep -q "metadata store --key __knit_pilotd_version__ --value 9.9.9" "${__pilotd_meta}"
    grep -q "download/v9.9.9/knit-pilotd-9.9.9.tar.gz" "${__pilotd_meta}"
}

@test "bootstrap knit-pilotd honours an explicit url override" {
    _setup_pilotd_decision

    _knit_bootstrap_pilotd "1.2.3" "https://example.com/pilotd.tgz"

    grep -q "https://example.com/pilotd.tgz" "${__pilotd_build_marker}"
    grep -q "metadata store --key __knit_pilotd_version__ --value 1.2.3" "${__pilotd_meta}"
    grep -q "metadata store --key __knit_pilotd_url__ --value https://example.com/pilotd.tgz" "${__pilotd_meta}"
}

# ---------- knit_with_pilot: markers ----------

# Return the value of a pilot marker variable for a job registered as
# "submit:<name>". Usage: _pilot_marker <name> <suffix> (suffix e.g. "pilot").
_pilot_marker() {
    local mangled
    _knit_command_mangle mangled "submit:$1"
    local var="_KNIT_CMD_${mangled}_$2"
    printf '%s' "${!var:-}"
}

@test "knit_with_pilot marks the job a pilot" {
    knit_register_job "campaign" _campaign_fn "A pilot campaign."
    knit_with_pilot
    _campaign_fn() { :; }
    knit_done

    [ "$(_pilot_marker campaign pilot)" = "1" ]
    # The optional policy markers are unset unless their flags were given.
    [ -z "$(_pilot_marker campaign pilot_exclude_launch_host)" ]
    [ -z "$(_pilot_marker campaign pilot_kill_on_exit)" ]
}

@test "knit_with_pilot --exclude-launch-host stores the marker" {
    knit_register_job "campaign" _campaign_fn "A pilot campaign."
    knit_with_pilot --exclude-launch-host
    _campaign_fn() { :; }
    knit_done

    [ "$(_pilot_marker campaign pilot)" = "1" ]
    [ "$(_pilot_marker campaign pilot_exclude_launch_host)" = "1" ]
}

@test "knit_with_pilot --kill-on-exit stores the marker" {
    knit_register_job "campaign" _campaign_fn "A pilot campaign."
    knit_with_pilot --kill-on-exit
    _campaign_fn() { :; }
    knit_done

    [ "$(_pilot_marker campaign pilot_kill_on_exit)" = "1" ]
}

@test "knit_with_pilot installs the pilot before/after callbacks" {
    knit_register_job "campaign" _campaign_fn "A pilot campaign."
    knit_with_pilot --exclude-launch-host
    _campaign_fn() { :; }
    knit_done

    local mangled
    _knit_command_mangle mangled "submit:campaign"
    local -n before="_KNIT_CMD_${mangled}_before_cb"
    local -n after="_KNIT_CMD_${mangled}_after_cb"
    # The pilot callbacks are appended after the generic job callbacks, and the
    # before-callback carries the --exclude-launch-host flag it was bound with.
    [[ "${before[*]}" == *"_knit_pilot_before_cb 1"* ]]
    [[ "${after[*]}" == *"_knit_pilot_after_cb"* ]]
}

# ---------- knit_with_pilot: rejections ----------

@test "knit_with_pilot is rejected outside a registration" {
    run knit_with_pilot
    [ "$status" -ne 0 ]
    [[ "$output" == *"between a knit_register_job call and knit_done"* ]]
}

@test "knit_with_pilot is rejected on a setup" {
    knit_register_setup "env" _env_fn "An env."
    run knit_with_pilot
    [ "$status" -ne 0 ]
    [[ "$output" == *"valid only for jobs"* ]]
}

@test "knit_with_pilot is rejected on a plain command" {
    knit_register "plain" _plain_fn "A plain command."
    run knit_with_pilot
    [ "$status" -ne 0 ]
    [[ "$output" == *"valid only for jobs"* ]]
}

@test "knit_with_pilot is rejected a second time on the same job" {
    knit_register_job "campaign" _campaign_fn "A pilot campaign."
    knit_with_pilot
    run knit_with_pilot
    [ "$status" -ne 0 ]
    [[ "$output" == *"at most once"* ]]
}

@test "knit_with_pilot rejects an unknown option" {
    knit_register_job "campaign" _campaign_fn "A pilot campaign."
    run knit_with_pilot --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown option"* ]]
}

# ---------- _knit_pilot_build_nodelist ----------

@test "build-nodelist joins the deduplicated hostnames" {
    knit_job_hostnames() { printf '%s\n' nodeA nodeB nodeC; }
    run _knit_pilot_build_nodelist ""
    [ "$status" -eq 0 ]
    [ "$output" = "nodeA,nodeB,nodeC" ]
}

@test "build-nodelist drops the launch host with --exclude-launch-host" {
    knit_job_hostnames() { printf '%s\n' nodeA nodeB nodeC; }
    hostname() { printf 'nodeB\n'; }
    run _knit_pilot_build_nodelist 1
    [ "$status" -eq 0 ]
    [ "$output" = "nodeA,nodeC" ]
}

@test "build-nodelist matches the launch host on its short name (FQDN)" {
    knit_job_hostnames() { printf '%s\n' nodeA nodeB nodeC; }
    hostname() { printf 'nodeB.example.com\n'; }
    run _knit_pilot_build_nodelist 1
    [ "$status" -eq 0 ]
    [ "$output" = "nodeA,nodeC" ]
}

@test "build-nodelist is a no-op exclude when the launch host is not in the pool" {
    knit_job_hostnames() { printf '%s\n' nodeA nodeB nodeC; }
    hostname() { printf 'login01\n'; }
    run _knit_pilot_build_nodelist 1
    [ "$status" -eq 0 ]
    [ "$output" = "nodeA,nodeB,nodeC" ]
}

# ---------- _knit_pilot_reject_nested_submit (the guard) ----------

@test "guard allows submit on the login side (no KNIT_JOB_PREFIX)" {
    unset KNIT_JOB_PREFIX
    run _knit_pilot_reject_nested_submit
    [ "$status" -eq 0 ]
}

@test "guard rejects a nested submit from a non-pilot job body" {
    export KNIT_JOB_PREFIX="${__TEST_TMPDIR}/job"
    unset KNIT_PILOT
    run _knit_pilot_reject_nested_submit
    [ "$status" -ne 0 ]
    [[ "$output" == *"knit_with_pilot"* ]]
}

@test "guard allows a nested submit inside a pilot job (KNIT_PILOT set)" {
    export KNIT_JOB_PREFIX="${__TEST_TMPDIR}/job"
    export KNIT_PILOT=1
    run _knit_pilot_reject_nested_submit
    [ "$status" -eq 0 ]
}
