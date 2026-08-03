#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
    TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "${TMP}"
}

# Populate a resolved-options associative array with a valid baseline. Callers
# override individual keys before invoking the backend under test.
_mk_opts() {
    local -n a="$1"
    a[job-name]="myjob"
    a[account]=""
    a[project]=""
    a[queue]=""
    a[nodes]="1"
    a[cpus-per-node]=""
    a[walltime]="01:00:00"
    a[gpus-per-node]="0"
    a[extra-args]=""
    a[wait]="false"
}

# ---------- _knit_sched_pbs_directives ----------

@test "pbs directives include the mandatory fields" {
    declare -A o
    _mk_opts o
    local out
    out="$(_knit_sched_pbs_directives o /jobs/x)"
    [[ "${out}" == *"#PBS -N myjob"* ]]
    [[ "${out}" == *"#PBS -l select=1"* ]]
    [[ "${out}" == *"#PBS -l walltime=01:00:00"* ]]
    [[ "${out}" == *"#PBS -l place=excl"* ]]
}

@test "pbs directives fix output and error to the job directory" {
    declare -A o
    _mk_opts o
    local out
    out="$(_knit_sched_pbs_directives o /path/to/job)"
    [[ "${out}" == *"#PBS -o /path/to/job/.stdout"* ]]
    [[ "${out}" == *"#PBS -e /path/to/job/.stderr"* ]]
}

@test "pbs directives omit optional fields when unset" {
    declare -A o
    _mk_opts o
    local out
    out="$(_knit_sched_pbs_directives o /jobs/x)"
    [[ "${out}" != *"#PBS -A "* ]]
    [[ "${out}" != *"#PBS -P "* ]]
    [[ "${out}" != *"#PBS -q "* ]]
    [[ "${out}" != *"ncpus="* ]]
    [[ "${out}" != *"mpiprocs="* ]]
    [[ "${out}" != *"ngpus="* ]]
}

@test "pbs directives emit account, project and queue when set" {
    declare -A o
    _mk_opts o
    o[account]="ACC"
    o[project]="PROJ"
    o[queue]="debug"
    local out
    out="$(_knit_sched_pbs_directives o /jobs/x)"
    [[ "${out}" == *"#PBS -A ACC"* ]]
    [[ "${out}" == *"#PBS -P PROJ"* ]]
    [[ "${out}" == *"#PBS -q debug"* ]]
}

@test "pbs select pins ncpus and mpiprocs to the derived core count" {
    declare -A o
    _mk_opts o
    o[nodes]="4"
    o[cpus-per-node]="32"
    local out
    out="$(_knit_sched_pbs_directives o /jobs/x)"
    [[ "${out}" == *"#PBS -l select=4:ncpus=32:mpiprocs=32"* ]]
}

@test "pbs select adds ngpus only when more than zero" {
    declare -A o
    _mk_opts o
    o[cpus-per-node]="8"
    o[gpus-per-node]="0"
    local out
    out="$(_knit_sched_pbs_directives o /jobs/x)"
    [[ "${out}" != *"ngpus="* ]]

    o[gpus-per-node]="2"
    out="$(_knit_sched_pbs_directives o /jobs/x)"
    [[ "${out}" == *"#PBS -l select=1:ncpus=8:mpiprocs=8:ngpus=2"* ]]
}

@test "pbs directives pass site scheduler args verbatim" {
    declare -A o
    _mk_opts o
    o[extra-args]="-l filesystems=home:eagle"
    local out
    out="$(_knit_sched_pbs_directives o /jobs/x)"
    [[ "${out}" == *"#PBS -l filesystems=home:eagle"* ]]
}

@test "pbs directives start every line with the #PBS prefix" {
    declare -A o
    _mk_opts o
    o[account]="ACC"
    o[queue]="debug"
    o[cpus-per-node]="8"
    o[gpus-per-node]="2"
    local out line
    out="$(_knit_sched_pbs_directives o /jobs/x)"
    while IFS= read -r line; do
        [[ "${line}" == "#PBS "* ]]
    done <<< "${out}"
}

# ---------- _knit_sched_pbs_parse_jobid ----------

@test "pbs parse_jobid strips the server suffix" {
    run _knit_sched_pbs_parse_jobid "98765.pbsserver"
    [ "${output}" = "98765" ]
}

@test "pbs parse_jobid handles a bare numeric id" {
    run _knit_sched_pbs_parse_jobid "123"
    [ "${output}" = "123" ]
}

@test "pbs parse_jobid keeps only the first line" {
    run _knit_sched_pbs_parse_jobid $'456.pbs-login\ntrailing noise'
    [ "${output}" = "456" ]
}

# ---------- _knit_sched_pbs_submit (mocked qsub) ----------

@test "pbs submit runs qsub without blocking and returns the parsed id" {
    declare -A o
    _mk_opts o
    o[wait]="false"
    qsub() { printf '%s\n' "$*" > "${TMP}/argv"; printf '7.pbs-login\n'; }

    local id
    id="$(_knit_sched_pbs_submit o /jobs/x/.job.sh /jobs/x)"
    [ "${id}" = "7" ]

    local argv
    argv="$(< "${TMP}/argv")"
    [[ "${argv}" != *"block=true"* ]]
    [[ "${argv}" == *"/jobs/x/.job.sh"* ]]
}

@test "pbs submit forwards -W block=true when the wait flag is set" {
    declare -A o
    _mk_opts o
    o[wait]="true"
    qsub() { printf '%s\n' "$*" > "${TMP}/argv"; printf '8.pbs-login\n'; }

    local id
    id="$(_knit_sched_pbs_submit o /jobs/x/.job.sh /jobs/x)"
    [ "${id}" = "8" ]

    local argv
    argv="$(< "${TMP}/argv")"
    [[ "${argv}" == *"-W block=true"* ]]
}

@test "pbs submit fails when qsub fails" {
    declare -A o
    _mk_opts o
    qsub() { return 1; }
    run _knit_sched_pbs_submit o /jobs/x/.job.sh /jobs/x
    [ "${status}" -ne 0 ]
}

# ---------- _knit_sched_pbs_cancel ----------

@test "pbs cancel calls qdel with the job id" {
    qdel() { printf '%s\n' "$*" > "${TMP}/argv"; }
    run _knit_sched_pbs_cancel 98765.pbsserver
    [ "${status}" -eq 0 ]
    [ "$(< "${TMP}/argv")" = "98765.pbsserver" ]
}
