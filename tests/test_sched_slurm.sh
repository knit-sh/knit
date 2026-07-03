#!/usr/bin/env bats

setup() {
    source knit.sh
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

# ---------- _knit_sched_slurm_directives ----------

@test "slurm directives include the mandatory fields" {
    declare -A o
    _mk_opts o
    local out
    out="$(_knit_sched_slurm_directives o /jobs/x)"
    [[ "${out}" == *"#SBATCH --job-name=myjob"* ]]
    [[ "${out}" == *"#SBATCH --nodes=1"* ]]
    [[ "${out}" == *"#SBATCH --time=01:00:00"* ]]
    [[ "${out}" == *"#SBATCH --exclusive"* ]]
}

@test "slurm directives request a pre-termination warning signal" {
    declare -A o
    _mk_opts o
    local out
    out="$(_knit_sched_slurm_directives o /jobs/x)"
    [[ "${out}" == *"#SBATCH --signal=B:USR1@${_KNIT_SCHED_KILL_WARNING_SEC}"* ]]
}

@test "slurm directives fix output and error to the job directory" {
    declare -A o
    _mk_opts o
    local out
    out="$(_knit_sched_slurm_directives o /path/to/job)"
    [[ "${out}" == *"#SBATCH --output=/path/to/job/.stdout"* ]]
    [[ "${out}" == *"#SBATCH --error=/path/to/job/.stderr"* ]]
}

@test "slurm directives omit optional fields when unset" {
    declare -A o
    _mk_opts o
    local out
    out="$(_knit_sched_slurm_directives o /jobs/x)"
    [[ "${out}" != *"--account="* ]]
    [[ "${out}" != *"--wckey="* ]]
    [[ "${out}" != *"--partition="* ]]
    [[ "${out}" != *"--ntasks-per-node="* ]]
    [[ "${out}" != *"--gpus-per-node="* ]]
}

@test "slurm directives emit account, project and partition when set" {
    declare -A o
    _mk_opts o
    o[account]="ACC"
    o[project]="PROJ"
    o[queue]="debug"
    local out
    out="$(_knit_sched_slurm_directives o /jobs/x)"
    [[ "${out}" == *"#SBATCH --account=ACC"* ]]
    [[ "${out}" == *"#SBATCH --wckey=PROJ"* ]]
    [[ "${out}" == *"#SBATCH --partition=debug"* ]]
}

@test "slurm directives pin ntasks-per-node to the derived core count" {
    declare -A o
    _mk_opts o
    o[cpus-per-node]="32"
    local out
    out="$(_knit_sched_slurm_directives o /jobs/x)"
    [[ "${out}" == *"#SBATCH --ntasks-per-node=32"* ]]
}

@test "slurm directives request gpus only when more than zero" {
    declare -A o
    _mk_opts o
    o[gpus-per-node]="0"
    local out
    out="$(_knit_sched_slurm_directives o /jobs/x)"
    [[ "${out}" != *"--gpus-per-node="* ]]

    o[gpus-per-node]="4"
    out="$(_knit_sched_slurm_directives o /jobs/x)"
    [[ "${out}" == *"#SBATCH --gpus-per-node=4"* ]]
}

@test "slurm directives pass site scheduler args verbatim" {
    declare -A o
    _mk_opts o
    o[extra-args]="-C nvme --qos=high"
    local out
    out="$(_knit_sched_slurm_directives o /jobs/x)"
    [[ "${out}" == *"#SBATCH -C nvme --qos=high"* ]]
}

@test "slurm directives start every line with the #SBATCH prefix" {
    declare -A o
    _mk_opts o
    o[account]="ACC"
    o[queue]="debug"
    o[cpus-per-node]="8"
    o[gpus-per-node]="2"
    local out line
    out="$(_knit_sched_slurm_directives o /jobs/x)"
    while IFS= read -r line; do
        [[ "${line}" == "#SBATCH "* ]]
    done <<< "${out}"
}

# ---------- _knit_sched_slurm_parse_jobid ----------

@test "slurm parse_jobid extracts the numeric id" {
    run _knit_sched_slurm_parse_jobid "Submitted batch job 12345"
    [ "${output}" = "12345" ]
}

@test "slurm parse_jobid ignores surrounding text" {
    run _knit_sched_slurm_parse_jobid $'a warning line\nSubmitted batch job 42\n'
    [ "${output}" = "42" ]
}

@test "slurm parse_jobid falls back to the last token" {
    run _knit_sched_slurm_parse_jobid "99999"
    [ "${output}" = "99999" ]
}

# ---------- _knit_sched_slurm_submit (mocked sbatch) ----------

@test "slurm submit runs sbatch without --wait and returns the parsed id" {
    declare -A o
    _mk_opts o
    o[wait]="false"
    sbatch() { printf '%s\n' "$*" > "${TMP}/argv"; printf 'Submitted batch job 7\n'; }

    local id
    id="$(_knit_sched_slurm_submit o /jobs/x/.job.sh /jobs/x)"
    [ "${id}" = "7" ]

    local argv
    argv="$(< "${TMP}/argv")"
    [[ "${argv}" != *"--wait"* ]]
    [[ "${argv}" == *"/jobs/x/.job.sh"* ]]
}

@test "slurm submit forwards --wait when the wait flag is set" {
    declare -A o
    _mk_opts o
    o[wait]="true"
    sbatch() { printf '%s\n' "$*" > "${TMP}/argv"; printf 'Submitted batch job 8\n'; }

    local id
    id="$(_knit_sched_slurm_submit o /jobs/x/.job.sh /jobs/x)"
    [ "${id}" = "8" ]

    local argv
    argv="$(< "${TMP}/argv")"
    [[ "${argv}" == *"--wait"* ]]
}

@test "slurm submit fails when sbatch fails" {
    declare -A o
    _mk_opts o
    sbatch() { return 1; }
    run _knit_sched_slurm_submit o /jobs/x/.job.sh /jobs/x
    [ "${status}" -ne 0 ]
}

# ---------- _knit_sched_slurm_cancel ----------

@test "slurm cancel calls scancel with the job id" {
    scancel() { printf '%s\n' "$*" > "${TMP}/argv"; }
    run _knit_sched_slurm_cancel 12345
    [ "${status}" -eq 0 ]
    [ "$(< "${TMP}/argv")" = "12345" ]
}
