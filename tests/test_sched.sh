#!/usr/bin/env bats

setup() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi
    if ! command -v jq &>/dev/null; then
        skip "jq not available"
    fi

    source knit.sh

    __KNIT_SQLITE_EXE="sqlite3"
    __KNIT_JQ_EXE="jq"
    __KNIT_DATABASE="$(mktemp --suffix=.db)"
    __KNIT_TEST_TMPDIR="$(mktemp -d)"

    # Satisfy the bootstrap check — tests in this file work with a live DB
    _KNIT_IS_BOOTSTRAPPED="1"

    _knit_create_metadata_table
}

teardown() {
    rm -f "${__KNIT_DATABASE}"
    rm -rf "${__KNIT_TEST_TMPDIR}"
    _KNIT_IS_BOOTSTRAPPED=""
}

# ---------- _knit_uuidv7 ----------

@test "_knit_uuidv7 produces a value of the uuid type" {
    local u
    u="$(_knit_uuidv7)"
    knit_type_check "uuid" "${u}"
}

@test "_knit_uuidv7 sets the version nibble to 7" {
    local u
    u="$(_knit_uuidv7)"
    [ "${u:14:1}" = "7" ]
}

@test "_knit_uuidv7 sets the variant nibble to one of 8,9,a,b" {
    local u
    u="$(_knit_uuidv7)"
    [[ "${u:19:1}" =~ ^[89ab]$ ]]
}

@test "_knit_uuidv7 produces distinct values" {
    local a b
    a="$(_knit_uuidv7)"
    b="$(_knit_uuidv7)"
    [ "${a}" != "${b}" ]
}

@test "_knit_uuidv7 values are lexically time-ordered" {
    local a b
    a="$(_knit_uuidv7)"
    sleep 0.01
    b="$(_knit_uuidv7)"
    [[ "${a}" < "${b}" ]]
}

# ---------- __knit_submit job directory creation ----------

@test "__knit_submit creates <setup>/jobs/<uuid> directory" {
    local setup_dir="${__KNIT_TEST_TMPDIR}/setup"
    mkdir -p "${setup_dir}"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done

    # __knit_submit is normally reached via _knit_invoke_command; when calling it
    # directly, provide the executing-command context that its knit_output /
    # _knit_set_row_id calls require.
    _KNIT_EXECUTING_COMMAND=("submit")
    __knit_submit --setup "${setup_dir}" -- myjob

    [ -d "${setup_dir}/jobs" ]
    local count
    count=$(find "${setup_dir}/jobs" -mindepth 1 -maxdepth 1 -type d | wc -l)
    [ "${count}" -eq 1 ]
}

@test "__knit_submit job directory name is a valid uuid" {
    local setup_dir="${__KNIT_TEST_TMPDIR}/setup"
    mkdir -p "${setup_dir}"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done

    # __knit_submit is normally reached via _knit_invoke_command; when calling it
    # directly, provide the executing-command context that its knit_output /
    # _knit_set_row_id calls require.
    _KNIT_EXECUTING_COMMAND=("submit")
    __knit_submit --setup "${setup_dir}" -- myjob

    local name
    name=$(find "${setup_dir}/jobs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
    knit_type_check "uuid" "${name}"
}

# ---------- _knit_sched_resolve : precedence ----------

@test "resolve uses the explicit argument over everything" {
    _knit_metadata_store --key "__default_queue__" --value "metaqueue"
    declare -A r
    _knit_sched_resolve r --queue cliqueue --nodes 8
    [ "${r[queue]}" = "cliqueue" ]
    [ "${r[nodes]}" = "8" ]
}

@test "resolve falls back to metadata when no explicit argument" {
    _knit_metadata_store --key "__default_queue__" --value "metaqueue"
    declare -A r
    _knit_sched_resolve r
    [ "${r[queue]}" = "metaqueue" ]
}

@test "resolve falls back to the profile when no metadata" {
    _knit_metadata_store --key "__profile__" --value "polaris"
    declare -A r
    _knit_sched_resolve r
    [ "${r[queue]}" = "prod" ]
}

@test "resolve prefers metadata over the profile" {
    _knit_metadata_store --key "__profile__" --value "polaris"
    _knit_metadata_store --key "__default_queue__" --value "metaqueue"
    declare -A r
    _knit_sched_resolve r
    [ "${r[queue]}" = "metaqueue" ]
}

@test "resolve falls back to hard-coded defaults when nothing is set" {
    declare -A r
    _knit_sched_resolve r
    [ "${r[nodes]}" = "1" ]
    [ "${r[gpus-per-node]}" = "0" ]
    [ "${r[walltime]}" = "01:00:00" ]
    [ "${r[wait]}" = "false" ]
}

@test "resolve leaves cpus-per-node empty when no profile or metadata" {
    declare -A r
    _knit_sched_resolve r
    [ -z "${r[cpus-per-node]}" ]
}

@test "resolve derives cpus-per-node from the profile hardware" {
    _knit_metadata_store --key "__profile__" --value "polaris"
    declare -A r
    _knit_sched_resolve r
    [ "${r[cpus-per-node]}" = "32" ]
}

@test "resolve prefers __node_ncpus__ metadata for cpus-per-node" {
    _knit_metadata_store --key "__profile__" --value "polaris"
    _knit_metadata_store --key "__node_ncpus__" --value "64"
    declare -A r
    _knit_sched_resolve r
    [ "${r[cpus-per-node]}" = "64" ]
}

@test "resolve tolerates absent metadata keys without error" {
    declare -A r
    run _knit_sched_resolve r
    [ "$status" -eq 0 ]
}

# ---------- _knit_sched_resolve : specific options ----------

@test "resolve derives walltime from the resolved queue's profile cap" {
    _knit_metadata_store --key "__profile__" --value "polaris"
    declare -A r
    # No explicit queue -> profile default queue "prod" (max_walltime 24:00:00)
    _knit_sched_resolve r
    [ "${r[walltime]}" = "24:00:00" ]
}

@test "resolve derives walltime from an explicitly chosen queue's cap" {
    _knit_metadata_store --key "__profile__" --value "polaris"
    declare -A r
    _knit_sched_resolve r --queue debug
    [ "${r[walltime]}" = "01:00:00" ]
}

@test "resolve job-name defaults to the experiment script name" {
    declare -A r
    _knit_sched_resolve r
    [ "${r[job-name]}" = "${KNIT_SCRIPT_NAME}" ]
}

@test "resolve job-name honours an explicit value" {
    declare -A r
    _knit_sched_resolve r --job-name myrun
    [ "${r[job-name]}" = "myrun" ]
}

@test "resolve reads account and project from metadata" {
    _knit_metadata_store --key "__account__" --value "ACC1"
    _knit_metadata_store --key "__project__" --value "PROJ1"
    declare -A r
    _knit_sched_resolve r
    [ "${r[account]}" = "ACC1" ]
    [ "${r[project]}" = "PROJ1" ]
}

@test "resolve captures site scheduler args from the profile" {
    _knit_metadata_store --key "__profile__" --value "polaris"
    declare -A r
    _knit_sched_resolve r
    [ "${r[extra-args]}" = "-l filesystems=home:eagle" ]
}

@test "resolve honours the wait flag" {
    declare -A r
    _knit_sched_resolve r --wait true
    [ "${r[wait]}" = "true" ]
}

# ---------- _knit_sched_validate_caps ----------

@test "validate_caps fatals when walltime exceeds the queue cap" {
    _knit_metadata_store --key "__profile__" --value "polaris"
    declare -A r
    r[queue]="debug"       # polaris debug: max_walltime 01:00:00, max_nodes 2
    r[walltime]="02:00:00"
    r[nodes]="1"
    run _knit_sched_validate_caps r
    [ "$status" -ne 0 ]
    [[ "$output" == *"exceeds"* ]]
}

@test "validate_caps passes when walltime is within the queue cap" {
    _knit_metadata_store --key "__profile__" --value "polaris"
    declare -A r
    r[queue]="debug"
    r[walltime]="00:30:00"
    r[nodes]="1"
    run _knit_sched_validate_caps r
    [ "$status" -eq 0 ]
}

@test "validate_caps fatals when nodes exceed the queue cap" {
    _knit_metadata_store --key "__profile__" --value "polaris"
    declare -A r
    r[queue]="debug"
    r[walltime]="00:10:00"
    r[nodes]="3"           # debug allows at most 2
    run _knit_sched_validate_caps r
    [ "$status" -ne 0 ]
    [[ "$output" == *"exceeds"* ]]
}

@test "validate_caps passes when nodes are within the queue cap" {
    _knit_metadata_store --key "__profile__" --value "polaris"
    declare -A r
    r[queue]="debug"
    r[walltime]="00:10:00"
    r[nodes]="2"
    run _knit_sched_validate_caps r
    [ "$status" -eq 0 ]
}

@test "validate_caps is a no-op when no profile is configured" {
    declare -A r
    r[queue]="debug"
    r[walltime]="99:00:00"
    r[nodes]="9999"
    run _knit_sched_validate_caps r
    [ "$status" -eq 0 ]
}

@test "validate_caps is a no-op for a queue that declares no caps" {
    _knit_metadata_store --key "__profile__" --value "polaris"
    declare -A r
    r[queue]="nosuchqueue"
    r[walltime]="99:00:00"
    r[nodes]="9999"
    run _knit_sched_validate_caps r
    [ "$status" -eq 0 ]
}
