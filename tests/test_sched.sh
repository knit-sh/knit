#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    _KNIT_TEST_TMPDIR="$(mktemp -d)"

    _knit_create_metadata_table
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
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

# ---------- _knit_submit job directory creation ----------

@test "_knit_submit creates <setup>/jobs/<uuid> directory" {
    local setup_dir="${_KNIT_TEST_TMPDIR}/setup"
    mkdir -p "${setup_dir}"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done

    # _knit_submit records its jobs row before dispatching, so the table
    # must exist (normally ensured lazily by _knit_invoke_command on first use).
    _knit_db_setup_table "submit" "jobs"

    # _knit_submit is normally reached via _knit_invoke_command; when calling it
    # directly, provide the executing-command context that its knit_output /
    # _knit_set_row_id calls require.
    _KNIT_EXECUTING_COMMAND=("submit")
    _knit_submit --setup "${setup_dir}" -- myjob

    [ -d "${setup_dir}/jobs" ]
    local count
    count=$(find "${setup_dir}/jobs" -mindepth 1 -maxdepth 1 -type d | wc -l)
    [ "${count}" -eq 1 ]
}

@test "_knit_submit job directory name is a valid uuid" {
    local setup_dir="${_KNIT_TEST_TMPDIR}/setup"
    mkdir -p "${setup_dir}"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done

    # _knit_submit records its jobs row before dispatching, so the table
    # must exist (normally ensured lazily by _knit_invoke_command on first use).
    _knit_db_setup_table "submit" "jobs"

    # _knit_submit is normally reached via _knit_invoke_command; when calling it
    # directly, provide the executing-command context that its knit_output /
    # _knit_set_row_id calls require.
    _KNIT_EXECUTING_COMMAND=("submit")
    _knit_submit --setup "${setup_dir}" -- myjob

    local name
    name=$(find "${setup_dir}/jobs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
    knit_type_check "uuid" "${name}"
}

@test "_knit_submit absolutizes a relative setup path in the batch script" {
    # The generated batch script cd's into the job dir before re-entering the
    # experiment, so KNIT_SETUP_PREFIX / KNIT_JOB_PREFIX / the cd target must be
    # absolute even when --setup is given as a relative path.
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    _knit_db_setup_table "submit" "jobs"

    _KNIT_EXECUTING_COMMAND=("submit")
    knit_pushd "${_KNIT_TEST_TMPDIR}"
    mkdir -p relsetup
    _knit_submit --setup ./relsetup -- myjob
    knit_popd

    local jobscript
    jobscript=$(find "${_KNIT_TEST_TMPDIR}/relsetup/jobs" \
        -name .job.sh -type f | head -1)
    [[ -n "${jobscript}" ]]
    grep -q "^export KNIT_SETUP_PREFIX=/" "${jobscript}"
    grep -q "^export KNIT_JOB_PREFIX=/" "${jobscript}"
    grep -q "^cd /" "${jobscript}"
}

@test "_knit_submit sources the setup .activate.sh in the batch script" {
    # The setup environment must be sourced before the experiment is re-entered
    # so that ENV[...] parameter defaults (resolved during argument expansion)
    # can see the variables the setup exported.
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    _knit_db_setup_table "submit" "jobs"

    local setup_dir="${_KNIT_TEST_TMPDIR}/setup"
    mkdir -p "${setup_dir}"

    _KNIT_EXECUTING_COMMAND=("submit")
    _knit_submit --setup "${setup_dir}" -- myjob

    local jobscript
    jobscript=$(find "${setup_dir}/jobs" -name .job.sh -type f | head -1)
    [[ -n "${jobscript}" ]]
    # The source line must come before the re-entry (exec) line.
    grep -q "^source ${setup_dir}/.activate.sh$" "${jobscript}"
    local src_line exec_line
    src_line=$(grep -n "^source ${setup_dir}/.activate.sh$" "${jobscript}" | cut -d: -f1)
    exec_line=$(grep -n "^exec " "${jobscript}" | cut -d: -f1)
    [ "${src_line}" -lt "${exec_line}" ]
}

@test "_knit_submit does not add a source line for a setup-less job" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    _knit_db_setup_table "submit" "jobs"

    _KNIT_EXECUTING_COMMAND=("submit")
    knit_pushd "${_KNIT_TEST_TMPDIR}"
    _knit_submit -- myjob
    knit_popd

    local jobscript
    jobscript=$(find "${_KNIT_TEST_TMPDIR}/jobs" -name .job.sh -type f | head -1)
    [[ -n "${jobscript}" ]]
    ! grep -q "^source .*/.activate.sh$" "${jobscript}"
}

# ---------- _knit_submit : setup requirement (knit_with_setup) ----------

@test "_knit_submit accepts a setup of the required type" {
    local setup_dir="${_KNIT_TEST_TMPDIR}/setup"
    mkdir -p "${setup_dir}"
    printf 'mcenv\n' > "${setup_dir}/.setup.type"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_done
    _knit_db_setup_table "submit" "jobs"

    _KNIT_EXECUTING_COMMAND=("submit")
    run _knit_submit --setup "${setup_dir}" -- myjob
    [ "$status" -eq 0 ]
    [ -d "${setup_dir}/jobs" ]
}

@test "_knit_submit rejects a setup built by a different type" {
    local setup_dir="${_KNIT_TEST_TMPDIR}/setup"
    mkdir -p "${setup_dir}"
    printf 'otherenv\n' > "${setup_dir}/.setup.type"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_done

    _KNIT_EXECUTING_COMMAND=("submit")
    run _knit_submit --setup "${setup_dir}" -- myjob
    [ "$status" -ne 0 ]
    [[ "$output" == *"mcenv"* ]]
    [[ "$output" == *"otherenv"* ]]
}

@test "_knit_submit rejects a setup with no recorded type" {
    local setup_dir="${_KNIT_TEST_TMPDIR}/setup"
    mkdir -p "${setup_dir}"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_done

    _KNIT_EXECUTING_COMMAND=("submit")
    run _knit_submit --setup "${setup_dir}" -- myjob
    [ "$status" -ne 0 ]
    [[ "$output" == *"no recorded type"* ]]
}

@test "_knit_submit requires --setup when the job declares a setup type" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_done

    _KNIT_EXECUTING_COMMAND=("submit")
    run _knit_submit -- myjob
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a --setup"* ]]
}

@test "_knit_submit runs a setup-less job under jobs/<uuid> without --setup" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    _knit_db_setup_table "submit" "jobs"

    _KNIT_EXECUTING_COMMAND=("submit")
    knit_pushd "${_KNIT_TEST_TMPDIR}"
    _knit_submit -- myjob
    knit_popd

    [ -d "${_KNIT_TEST_TMPDIR}/jobs" ]
    local jobscript
    jobscript=$(find "${_KNIT_TEST_TMPDIR}/jobs" -name .job.sh -type f | head -1)
    [[ -n "${jobscript}" ]]
    # A setup-less job must not export KNIT_SETUP_PREFIX in its batch script.
    ! grep -q "KNIT_SETUP_PREFIX" "${jobscript}"
}

@test "_knit_submit records the resolved scheduler command in native_cmd" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    _knit_db_setup_table "submit" "jobs"

    # Pin the backend and stub the actual submission so no real scheduler (or
    # background job) runs; native_cmd is recorded from the built command.
    _knit_sched_backend() { printf 'slurm\n'; }
    _knit_sched_submit() { printf '12345\n'; }

    _KNIT_EXECUTING_COMMAND=("submit")
    knit_pushd "${_KNIT_TEST_TMPDIR}"
    _knit_submit -- myjob
    knit_popd

    run sqlite3 "${_KNIT_DATABASE}" "SELECT native_cmd FROM jobs;"
    [[ "$output" == "sbatch "*"/.job.sh" ]]
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

# ---------- _knit_sched_cancel ----------

@test "_knit_sched_cancel dispatches to the backend cancel primitive" {
    _knit_sched_local_cancel() { printf 'local:%s\n' "$1" > "${_KNIT_TEST_TMPDIR}/c"; }
    _knit_sched_none_cancel()  { printf 'none:%s\n'  "$1" > "${_KNIT_TEST_TMPDIR}/c"; }
    _knit_sched_slurm_cancel() { printf 'slurm:%s\n' "$1" > "${_KNIT_TEST_TMPDIR}/c"; }
    _knit_sched_pbs_cancel()   { printf 'pbs:%s\n'   "$1" > "${_KNIT_TEST_TMPDIR}/c"; }

    _knit_sched_cancel local 111
    [ "$(< "${_KNIT_TEST_TMPDIR}/c")" = "local:111" ]
    _knit_sched_cancel none 444
    [ "$(< "${_KNIT_TEST_TMPDIR}/c")" = "none:444" ]
    _knit_sched_cancel slurm 222
    [ "$(< "${_KNIT_TEST_TMPDIR}/c")" = "slurm:222" ]
    _knit_sched_cancel pbs 333
    [ "$(< "${_KNIT_TEST_TMPDIR}/c")" = "pbs:333" ]
}

@test "_knit_sched_cancel fatals on an unknown backend" {
    run _knit_sched_cancel bogus 111
    [ "$status" -ne 0 ]
    [[ "$output" == *"not implemented"* ]]
}

# ---------- _knit_sched_submit_cmdline ----------

@test "_knit_sched_submit_cmdline builds each backend's submission argv" {
    declare -A opts=([wait]=false)
    local -a argv

    _knit_sched_submit_cmdline local opts /d/.job.sh argv
    [ "${argv[*]}" = "bash /d/.job.sh" ]

    _knit_sched_submit_cmdline none opts /d/.job.sh argv
    [ "${argv[*]}" = "bash /d/.job.sh" ]

    _knit_sched_submit_cmdline slurm opts /d/.job.sh argv
    [ "${argv[*]}" = "sbatch /d/.job.sh" ]

    _knit_sched_submit_cmdline pbs opts /d/.job.sh argv
    [ "${argv[*]}" = "qsub /d/.job.sh" ]
}

@test "_knit_sched_submit_cmdline threads the wait flag to slurm and pbs" {
    declare -A opts=([wait]=true)
    local -a argv

    _knit_sched_submit_cmdline slurm opts /d/.job.sh argv
    [ "${argv[*]}" = "sbatch --wait /d/.job.sh" ]

    _knit_sched_submit_cmdline pbs opts /d/.job.sh argv
    [ "${argv[*]}" = "qsub -W block=true /d/.job.sh" ]
}

@test "_knit_sched_submit_cmdline fatals on an unknown backend" {
    declare -A opts=([wait]=false)
    local -a argv
    run _knit_sched_submit_cmdline bogus opts /d/.job.sh argv
    [ "$status" -ne 0 ]
    [[ "$output" == *"not implemented"* ]]
}

# ---------- _knit_sched_backend ----------

@test "_knit_sched_backend honours an explicit 'none' from metadata" {
    _knit_metadata_load() { printf 'none\n'; }
    run _knit_sched_backend
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "_knit_sched_backend passes slurm/pbs/local metadata through" {
    _knit_metadata_load() { printf 'slurm\n'; }
    run _knit_sched_backend
    [ "$output" = "slurm" ]
    _knit_metadata_load() { printf 'pbs\n'; }
    run _knit_sched_backend
    [ "$output" = "pbs" ]
    _knit_metadata_load() { printf 'local\n'; }
    run _knit_sched_backend
    [ "$output" = "local" ]
}

@test "_knit_sched_backend maps detection's <unknown> to local when unbootstrapped" {
    _knit_metadata_load() { printf '\n'; }
    _knit_detect_job_manager() { printf '<unknown>\n'; }
    run _knit_sched_backend
    [ "$status" -eq 0 ]
    [ "$output" = "local" ]
}

@test "_knit_sched_backend uses detection when metadata is empty" {
    _knit_metadata_load() { printf '\n'; }
    _knit_detect_job_manager() { printf 'slurm\n'; }
    run _knit_sched_backend
    [ "$output" = "slurm" ]
}
