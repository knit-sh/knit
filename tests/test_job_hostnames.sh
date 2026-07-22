#!/usr/bin/env bats

setup() {
    source knit.sh

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    # Used by the --json cases; guarded per-test on jq availability.
    _KNIT_JQ_EXE="$(command -v jq || true)"
}

# Replace the backend host source with a fixture exercising the two raw hostfile
# shapes knit_job_hostnames must normalise: a repeated hostname and a ":N" slot
# suffix. Opt-in per test so the dispatcher test can use the real function.
_use_fixture() {
    _knit_sched_hostfile() {
        printf 'nodeA\nnodeA:4\nnodeB\nnodeB\n'
    }
}

# A larger fixture for --select slicing: raw is 5 lines
# (nodeA, nodeA:4, nodeB, nodeC, nodeD); deduped is 4 (nodeA..nodeD).
_use_fixture4() {
    _knit_sched_hostfile() {
        printf 'nodeA\nnodeA:4\nnodeB\nnodeC\nnodeD\n'
    }
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    unset PBS_NODEFILE SLURM_JOB_NODELIST SLURM_NODELIST
}

# ---------- knit_job_hostnames: formatting ----------

@test "default output is deduplicated, stripped, one host per line" {
    _use_fixture
    run knit_job_hostnames
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "nodeA" ]
    [ "${lines[1]}" = "nodeB" ]
}

@test "--separator joins deduplicated hosts with the given string" {
    _use_fixture
    run knit_job_hostnames --separator ,
    [ "${status}" -eq 0 ]
    [ "${output}" = "nodeA,nodeB" ]
}

@test "--separator supports a multi-character separator" {
    _use_fixture
    run knit_job_hostnames --separator ", "
    [ "${status}" -eq 0 ]
    [ "${output}" = "nodeA, nodeB" ]
}

@test "--json prints a JSON array of the deduplicated hosts" {
    _use_fixture
    [ -n "${_KNIT_JQ_EXE}" ] || skip "jq not available"
    run knit_job_hostnames --json
    [ "${status}" -eq 0 ]
    [ "${output}" = '["nodeA","nodeB"]' ]
}

@test "--raw prints the hostfile entries verbatim" {
    _use_fixture
    run knit_job_hostnames --raw
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
    [ "${lines[0]}" = "nodeA" ]
    [ "${lines[1]}" = "nodeA:4" ]
    [ "${lines[2]}" = "nodeB" ]
    [ "${lines[3]}" = "nodeB" ]
}

@test "--raw honours a custom separator" {
    _use_fixture
    run knit_job_hostnames --raw --separator ,
    [ "${status}" -eq 0 ]
    [ "${output}" = "nodeA,nodeA:4,nodeB,nodeB" ]
}

@test "--json wins over --separator and warns" {
    _use_fixture
    [ -n "${_KNIT_JQ_EXE}" ] || skip "jq not available"
    run knit_job_hostnames --json --separator ,
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'["nodeA","nodeB"]'* ]]
    [[ "${output}" == *"ignored"* ]]
}

@test "empty host list prints nothing by default" {
    _knit_sched_hostfile() { :; }
    run knit_job_hostnames
    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
}

@test "empty host list prints an empty JSON array with --json" {
    [ -n "${_KNIT_JQ_EXE}" ] || skip "jq not available"
    _knit_sched_hostfile() { :; }
    run knit_job_hostnames --json
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
}

@test "unknown argument is rejected" {
    _use_fixture
    run knit_job_hostnames --bogus
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unknown argument"* ]]
}

# ---------- knit_job_hostnames: --select ----------

@test "--select takes a length slice from the start index (0-based)" {
    _use_fixture4
    run knit_job_hostnames --select 0:2
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "nodeA" ]
    [ "${lines[1]}" = "nodeB" ]
}

@test "--select honours a non-zero start index" {
    _use_fixture4
    run knit_job_hostnames --select 1:2
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "nodeB" ]
    [ "${lines[1]}" = "nodeC" ]
}

@test "--select clamps a length that runs past the end" {
    _use_fixture4
    run knit_job_hostnames --select 2:10
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "nodeC" ]
    [ "${lines[1]}" = "nodeD" ]
}

@test "--select with a start past the end prints nothing" {
    _use_fixture4
    run knit_job_hostnames --select 10:2
    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
}

@test "--select with zero length prints nothing" {
    _use_fixture4
    run knit_job_hostnames --select 1:0
    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
}

@test "--select slices the raw list when combined with --raw" {
    _use_fixture4
    run knit_job_hostnames --raw --select 1:2
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "nodeA:4" ]
    [ "${lines[1]}" = "nodeB" ]
}

@test "--select combines with --separator" {
    _use_fixture4
    run knit_job_hostnames --select 1:2 --separator ,
    [ "${status}" -eq 0 ]
    [ "${output}" = "nodeB,nodeC" ]
}

@test "--select combines with --json" {
    _use_fixture4
    [ -n "${_KNIT_JQ_EXE}" ] || skip "jq not available"
    run knit_job_hostnames --json --select 0:2
    [ "${status}" -eq 0 ]
    [ "${output}" = '["nodeA","nodeB"]' ]
}

@test "--select accepts the --select=value form" {
    _use_fixture4
    run knit_job_hostnames --select=2:1
    [ "${status}" -eq 0 ]
    [ "${output}" = "nodeC" ]
}

@test "--select rejects a malformed value" {
    _use_fixture4
    run knit_job_hostnames --select 1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--select must be"* ]]
}

@test "--select rejects non-numeric indices" {
    _use_fixture4
    run knit_job_hostnames --select a:b
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--select must be"* ]]
}

# ---------- per-backend host sources ----------

@test "pbs hostfile cats \$PBS_NODEFILE" {
    local nf="${_KNIT_TEST_TMPDIR}/nodefile"
    printf 'c1\nc1\nc2\n' > "${nf}"
    export PBS_NODEFILE="${nf}"
    run _knit_sched_pbs_hostfile
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[0]}" = "c1" ]
    [ "${lines[2]}" = "c2" ]
}

@test "pbs hostfile falls back to hostname when \$PBS_NODEFILE is unset" {
    unset PBS_NODEFILE
    run _knit_sched_pbs_hostfile
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"$(hostname)"* ]]
}

@test "local hostfile is the local hostname" {
    run _knit_sched_local_hostfile
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(hostname)" ]
}

@test "none hostfile reads the configured nodefile" {
    local nf="${_KNIT_TEST_TMPDIR}/nodes"
    printf 'c1\nc1\nc2\n' > "${nf}"
    _knit_metadata_get() { local -n __r=$1; __r="${nf}"; }
    run _knit_sched_none_hostfile
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[0]}" = "c1" ]
    [ "${lines[2]}" = "c2" ]
}

@test "none hostfile falls back to hostname when no nodefile is configured" {
    _knit_metadata_get() { local -n __r=$1; __r=''; }
    run _knit_sched_none_hostfile
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"$(hostname)"* ]]
}

@test "slurm hostfile expands the nodelist via scontrol" {
    scontrol() { printf 'n1\nn2\n'; }
    export SLURM_JOB_NODELIST="n[1-2]"
    run _knit_sched_slurm_hostfile
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "n1" ]
    [ "${lines[1]}" = "n2" ]
}

@test "slurm hostfile falls back to hostname when nodelist is unset" {
    unset SLURM_JOB_NODELIST SLURM_NODELIST
    run _knit_sched_slurm_hostfile
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"$(hostname)"* ]]
}

@test "hostfile dispatcher routes to the resolved backend" {
    # Uses the real _knit_sched_hostfile (the fixture is opt-in), stubbing only
    # its backend resolution and the per-backend source it should route to.
    _knit_sched_backend() { local -n __r=$1; __r='pbs'; }
    _knit_sched_pbs_hostfile() { printf 'ROUTED\n'; }
    run _knit_sched_hostfile
    [ "${status}" -eq 0 ]
    [ "${output}" = "ROUTED" ]
}

@test "hostfile dispatcher routes to the none backend" {
    _knit_sched_backend() { local -n __r=$1; __r='none'; }
    _knit_sched_none_hostfile() { printf 'NONE-ROUTED\n'; }
    run _knit_sched_hostfile
    [ "${status}" -eq 0 ]
    [ "${output}" = "NONE-ROUTED" ]
}
