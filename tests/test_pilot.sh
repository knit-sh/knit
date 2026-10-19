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

# ---------- the pilot scheduler backend ----------

# Install a fake knit-pilotd that records its argv to a file and exits with a
# chosen code. _KNIT_PILOTD_EXE is frozen from _KNIT_PREFIX at source time, so
# each backend test points it at the fake explicitly.
__pilotd_args=""
_make_fake_pilotd() {
    local rc="${1:-0}"
    __pilotd_args="${__TEST_TMPDIR}/pilotd-argv"
    _KNIT_PILOTD_EXE="${__TEST_TMPDIR}/fake-pilotd"
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" > %q\n' "${__pilotd_args}"
        printf 'exit %s\n' "${rc}"
    } > "${_KNIT_PILOTD_EXE}"
    chmod +x "${_KNIT_PILOTD_EXE}"
}

@test "backend resolves to pilot when KNIT_PILOT is set" {
    export KNIT_PILOT=1
    local b
    _knit_sched_backend b
    [ "$b" = "pilot" ]
}

@test "backend ignores the pilot and uses the real backend otherwise" {
    unset KNIT_PILOT
    _knit_metadata_get() { local -n __o=$1; __o="slurm"; }
    local b
    _knit_sched_backend b
    [ "$b" = "slurm" ]
}

@test "real backend ignores an active pilot" {
    export KNIT_PILOT=1
    _knit_metadata_get() { local -n __o=$1; __o="pbs"; }
    local b
    _knit_sched_real_backend b
    [ "$b" = "pbs" ]
}

@test "pilot submit sends the daemon request and returns the sub-job UUID" {
    _make_fake_pilotd 0
    export KNIT_PILOT_SOCK="${__TEST_TMPDIR}/pilot.sock"
    local jobdir="${__TEST_TMPDIR}/jobs/0d1e2f3a"
    mkdir -p "${jobdir}"
    declare -A opts=([nodes]=3)

    run _knit_sched_pilot_submit opts "${jobdir}/.job.sh" "${jobdir}"
    [ "$status" -eq 0 ]
    # Prints the sub-job UUID (the job directory's basename) as the backend id.
    [ "$output" = "0d1e2f3a" ]

    # The daemon request carries the id, node count, socket, redirections, and the
    # "bash <script>" command after --.
    local argv; argv="$(cat "${__pilotd_args}")"
    [[ "${argv}" == *"submit"* ]]
    [[ "${argv}" == *"--socket ${KNIT_PILOT_SOCK}"* ]]
    [[ "${argv}" == *"--id 0d1e2f3a"* ]]
    [[ "${argv}" == *"--nodes 3"* ]]
    [[ "${argv}" == *"--out ${jobdir}/.stdout"* ]]
    [[ "${argv}" == *"-- bash ${jobdir}/.job.sh"* ]]
}

@test "pilot submit propagates a daemon rejection as a non-zero status" {
    _make_fake_pilotd 1
    export KNIT_PILOT_SOCK="${__TEST_TMPDIR}/pilot.sock"
    local jobdir="${__TEST_TMPDIR}/jobs/abc"
    mkdir -p "${jobdir}"
    declare -A opts=([nodes]=1)

    run _knit_sched_pilot_submit opts "${jobdir}/.job.sh" "${jobdir}"
    [ "$status" -ne 0 ]
    # Nothing is printed when the daemon rejects.
    [ -z "$output" ]
}

@test "pilot submit cmdline records the essential daemon command" {
    _KNIT_PILOTD_EXE="/some/where/knit-pilotd"
    declare -A opts=([nodes]=4)
    local -a argv=()
    _knit_sched_pilot_submit_cmdline argv opts "/j/.job.sh"
    [ "${argv[*]}" = "/some/where/knit-pilotd submit --nodes 4 -- bash /j/.job.sh" ]
}

@test "pilot wait asks the daemon and returns completed as success" {
    _make_fake_pilotd 0
    export KNIT_PILOT_SOCK="${__TEST_TMPDIR}/pilot.sock"
    run _knit_sched_pilot_wait "myid"
    [ "$status" -eq 0 ]
    [[ "$(cat "${__pilotd_args}")" == *"wait --socket ${KNIT_PILOT_SOCK} --id myid"* ]]
}

@test "pilot wait returns non-zero when the daemon reports failed/killed" {
    _make_fake_pilotd 1
    export KNIT_PILOT_SOCK="${__TEST_TMPDIR}/pilot.sock"
    run _knit_sched_pilot_wait "myid"
    [ "$status" -ne 0 ]
}

@test "pilot cancel asks the daemon to kill the sub-job" {
    _make_fake_pilotd 0
    export KNIT_PILOT_SOCK="${__TEST_TMPDIR}/pilot.sock"
    run _knit_sched_pilot_cancel "myid"
    [ "$status" -eq 0 ]
    [[ "$(cat "${__pilotd_args}")" == *"cancel --socket ${KNIT_PILOT_SOCK} --id myid"* ]]
}

@test "pilot submit fatals when no control socket is set" {
    unset KNIT_PILOT_SOCK
    declare -A opts=([nodes]=1)
    run _knit_sched_pilot_submit opts "/j/.job.sh" "/j"
    [ "$status" -ne 0 ]
    [[ "$output" == *"KNIT_PILOT_SOCK"* ]]
}

# ---------- pilot sub-job hostfile ----------

@test "pilot hostfile reads the daemon-assigned KNIT_PILOT_HOSTFILE" {
    export KNIT_PILOT_HOSTFILE="${__TEST_TMPDIR}/hostfile"
    printf '%s\n' nodeA nodeB > "${KNIT_PILOT_HOSTFILE}"
    run _knit_sched_pilot_hostfile
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "nodeA" ]
    [ "${lines[1]}" = "nodeB" ]
}

@test "pilot hostfile falls back to the local hostname when unset" {
    unset KNIT_PILOT_HOSTFILE
    hostname() { printf 'localnode\n'; }
    run _knit_sched_pilot_hostfile
    [ "$status" -eq 0 ]
    [[ "$output" == *"localnode"* ]]
}

@test "the host dispatcher routes a sub-job to the pilot hostfile" {
    export KNIT_PILOT_HOSTFILE="${__TEST_TMPDIR}/hostfile"
    printf '%s\n' subnodeA subnodeB > "${KNIT_PILOT_HOSTFILE}"
    run _knit_sched_hostfile
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "subnodeA" ]
    [ "${lines[1]}" = "subnodeB" ]
}
