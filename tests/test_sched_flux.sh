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

# ---------- _knit_sched_flux_walltime_fsd ----------

@test "flux walltime converts HH:MM:SS to seconds with an s suffix" {
    run _knit_sched_flux_walltime_fsd "01:00:00"
    [ "${output}" = "3600s" ]
}

@test "flux walltime converts a mixed HH:MM:SS value" {
    run _knit_sched_flux_walltime_fsd "02:30:15"
    [ "${output}" = "9015s" ]
}

@test "flux walltime treats leading-zero fields as decimal" {
    run _knit_sched_flux_walltime_fsd "00:09:08"
    [ "${output}" = "548s" ]
}

@test "flux walltime passes a non HH:MM:SS value through verbatim" {
    run _knit_sched_flux_walltime_fsd "30m"
    [ "${output}" = "30m" ]
}

# ---------- _knit_sched_flux_directives ----------

@test "flux directives include the mandatory fields" {
    declare -A o
    _mk_opts o
    local out
    out="$(_knit_sched_flux_directives o /jobs/x)"
    [[ "${out}" == *"# flux: --job-name=myjob"* ]]
    [[ "${out}" == *"# flux: --nodes=1"* ]]
    [[ "${out}" == *"# flux: --exclusive"* ]]
    [[ "${out}" == *"# flux: --time-limit=3600s"* ]]
}

@test "flux directives fix output and error to the job directory" {
    declare -A o
    _mk_opts o
    local out
    out="$(_knit_sched_flux_directives o /path/to/job)"
    [[ "${out}" == *"# flux: --output=/path/to/job/.stdout"* ]]
    [[ "${out}" == *"# flux: --error=/path/to/job/.stderr"* ]]
}

@test "flux directives omit optional fields when unset" {
    declare -A o
    _mk_opts o
    local out
    out="$(_knit_sched_flux_directives o /jobs/x)"
    [[ "${out}" != *"--bank="* ]]
    [[ "${out}" != *"--queue="* ]]
    [[ "${out}" != *"--gpus-per-slot="* ]]
}

@test "flux directives emit bank and queue when set" {
    declare -A o
    _mk_opts o
    o[account]="ACC"
    o[queue]="debug"
    local out
    out="$(_knit_sched_flux_directives o /jobs/x)"
    [[ "${out}" == *"# flux: --bank=ACC"* ]]
    [[ "${out}" == *"# flux: --queue=debug"* ]]
}

@test "flux directives request gpus-per-slot only when more than zero" {
    declare -A o
    _mk_opts o
    o[gpus-per-node]="0"
    local out
    out="$(_knit_sched_flux_directives o /jobs/x)"
    [[ "${out}" != *"--gpus-per-slot="* ]]

    o[gpus-per-node]="4"
    out="$(_knit_sched_flux_directives o /jobs/x)"
    [[ "${out}" == *"# flux: --gpus-per-slot=4"* ]]
}

@test "flux directives omit the per-node core count" {
    declare -A o
    _mk_opts o
    o[cpus-per-node]="32"
    local out
    out="$(_knit_sched_flux_directives o /jobs/x)"
    [[ "${out}" != *"cores-per"* ]]
    [[ "${out}" != *"tasks-per"* ]]
    [[ "${out}" != *"32"* ]]
}

@test "flux directives pass site scheduler args verbatim" {
    declare -A o
    _mk_opts o
    o[extra-args]="--setattr=system.bank=x"
    local out
    out="$(_knit_sched_flux_directives o /jobs/x)"
    [[ "${out}" == *"# flux: --setattr=system.bank=x"* ]]
}

@test "flux directives start every line with the # flux: prefix" {
    declare -A o
    _mk_opts o
    o[account]="ACC"
    o[queue]="debug"
    o[gpus-per-node]="2"
    local out line
    out="$(_knit_sched_flux_directives o /jobs/x)"
    while IFS= read -r line; do
        [[ "${line}" == "# flux: "* ]]
    done <<< "${out}"
}

# ---------- _knit_sched_flux_parse_jobid ----------

@test "flux parse_jobid keeps the bare FLUID token" {
    run _knit_sched_flux_parse_jobid "f2QzoR8xF"
    [ "${output}" = "f2QzoR8xF" ]
}

@test "flux parse_jobid trims surrounding whitespace" {
    run _knit_sched_flux_parse_jobid "  f2QzoR8xF  "
    [ "${output}" = "f2QzoR8xF" ]
}

@test "flux parse_jobid keeps only the first line" {
    run _knit_sched_flux_parse_jobid $'fABCdef\ntrailing noise'
    [ "${output}" = "fABCdef" ]
}

# ---------- _knit_sched_flux_submit (mocked flux) ----------

@test "flux submit runs flux batch and returns the parsed id" {
    declare -A o
    _mk_opts o
    o[wait]="false"
    flux() { printf '%s\n' "$*" > "${TMP}/argv"; printf 'f2QzoR8xF\n'; }

    local id
    id="$(_knit_sched_flux_submit o /jobs/x/.job.sh /jobs/x)"
    [ "${id}" = "f2QzoR8xF" ]

    local argv
    argv="$(< "${TMP}/argv")"
    [[ "${argv}" == "batch /jobs/x/.job.sh" ]]
}

@test "flux submit blocks with flux job status when the wait flag is set" {
    declare -A o
    _mk_opts o
    o[wait]="true"
    flux() {
        printf '%s\n' "$*" >> "${TMP}/calls"
        case "$1" in
            batch) printf 'f8\n' ;;
        esac
    }

    local id
    id="$(_knit_sched_flux_submit o /jobs/x/.job.sh /jobs/x)"
    [ "${id}" = "f8" ]

    local calls
    calls="$(< "${TMP}/calls")"
    [[ "${calls}" == *"batch /jobs/x/.job.sh"* ]]
    [[ "${calls}" == *"job status f8"* ]]
}

@test "flux submit does not wait when the wait flag is unset" {
    declare -A o
    _mk_opts o
    o[wait]="false"
    flux() {
        printf '%s\n' "$*" >> "${TMP}/calls"
        case "$1" in
            batch) printf 'f9\n' ;;
        esac
    }

    _knit_sched_flux_submit o /jobs/x/.job.sh /jobs/x >/dev/null

    local calls
    calls="$(< "${TMP}/calls")"
    [[ "${calls}" != *"job status"* ]]
}

@test "flux submit fails when flux batch fails" {
    declare -A o
    _mk_opts o
    flux() { return 1; }
    run _knit_sched_flux_submit o /jobs/x/.job.sh /jobs/x
    [ "${status}" -ne 0 ]
}

# ---------- _knit_sched_flux_submit_cmdline ----------

@test "flux submit_cmdline builds flux batch <script>" {
    declare -A o
    _mk_opts o
    local -a argv=()
    _knit_sched_flux_submit_cmdline argv o /jobs/x/.job.sh
    [ "${argv[0]}" = "flux" ]
    [ "${argv[1]}" = "batch" ]
    [ "${argv[2]}" = "/jobs/x/.job.sh" ]
}

# ---------- _knit_sched_flux_wait ----------

@test "flux wait calls flux job status with the job id" {
    flux() { printf '%s\n' "$*" > "${TMP}/argv"; }
    run _knit_sched_flux_wait f2QzoR8xF
    [ "${status}" -eq 0 ]
    [ "$(< "${TMP}/argv")" = "job status f2QzoR8xF" ]
}

# ---------- _knit_sched_flux_cancel ----------

@test "flux cancel calls flux cancel with the job id" {
    flux() { printf '%s\n' "$*" > "${TMP}/argv"; }
    run _knit_sched_flux_cancel f2QzoR8xF
    [ "${status}" -eq 0 ]
    [ "$(< "${TMP}/argv")" = "cancel f2QzoR8xF" ]
}

@test "flux cancel ignores a failing flux cancel" {
    flux() { return 1; }
    run _knit_sched_flux_cancel f2QzoR8xF
    [ "${status}" -eq 0 ]
}

# ---------- _knit_sched_flux_hostfile ----------

@test "flux hostfile prints the flux hostlist output" {
    flux() { printf 'flux-compute1\nflux-compute2\n'; }
    run _knit_sched_flux_hostfile
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"flux-compute1"* ]]
    [[ "${output}" == *"flux-compute2"* ]]
}

@test "flux hostfile falls back to the local hostname when flux fails" {
    flux() { return 1; }
    hostname() { printf 'fallback-host\n'; }
    run _knit_sched_flux_hostfile
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"fallback-host"* ]]
}
