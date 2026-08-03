#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    _KNIT_TEST_TMPDIR="$(mktemp -d)"

    # Pin the experiment root so setups resolve deterministically under
    # <experiment-root>/setups (the __setup_path__ fallback); --setup values are
    # names resolved there.
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    _KNIT_TEST_SETUP_ROOT="${_KNIT_TEST_TMPDIR}/setups"

    _knit_create_metadata_table
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

# Configure the experiment's profile the way bootstrap does: store the resolved
# JSON under __profile_json__ (run-time field reads go through it) plus the label
# under __profile__ (the gate). The JSON is read from the in-repo profile store.
_use_profile() {
    local name="$1" f
    f="$(find "${BATS_TEST_DIRNAME}/../src/profiles" -name "${name}.json" | head -1)"
    _knit_metadata_store --key "__profile__" --value "${name}"
    _knit_metadata_store --key "__profile_json__" --value "$(cat "${f}")"
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

@test "_knit_submit creates <job-root>/<uuid> directory" {
    local setup_dir="${_KNIT_TEST_SETUP_ROOT}/setup"
    mkdir -p "${setup_dir}"
    printf 'mcenv\n' > "${setup_dir}/.setup.type"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_done

    # _knit_submit records its jobs row before dispatching, so the table
    # must exist (normally ensured lazily by _knit_invoke_command on first use).
    _knit_db_setup_table "submit" "jobs"

    # _knit_submit is normally reached via _knit_invoke_command; when calling it
    # directly, provide the executing-command context that its knit_output /
    # _knit_set_row_id calls require.
    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    _knit_submit --setup "setup" -- myjob

    # The job lands in the unified job root (<experiment-root>/jobs), not under
    # the setup it uses.
    local jobs_root="${_KNIT_TEST_TMPDIR}/jobs"
    [ -d "${jobs_root}" ]
    [ ! -d "${setup_dir}/jobs" ]
    local count
    count=$(find "${jobs_root}" -mindepth 1 -maxdepth 1 -type d | wc -l)
    [ "${count}" -eq 1 ]
}

@test "_knit_submit job directory name is a valid uuid" {
    local setup_dir="${_KNIT_TEST_SETUP_ROOT}/setup"
    mkdir -p "${setup_dir}"
    printf 'mcenv\n' > "${setup_dir}/.setup.type"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_done

    # _knit_submit records its jobs row before dispatching, so the table
    # must exist (normally ensured lazily by _knit_invoke_command on first use).
    _knit_db_setup_table "submit" "jobs"

    # _knit_submit is normally reached via _knit_invoke_command; when calling it
    # directly, provide the executing-command context that its knit_output /
    # _knit_set_row_id calls require.
    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    _knit_submit --setup "setup" -- myjob

    local name
    name=$(find "${_KNIT_TEST_TMPDIR}/jobs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
    knit_type_check "uuid" "${name}"
}

# ---------- _knit_submit : --name alias ----------

@test "_knit_submit --name creates an alias symlink and records the name" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_without_setup
    knit_done
    _knit_db_setup_table "submit" "jobs"

    # Stub dispatch so no real scheduler/background job runs and stdout carries
    # only the returned job UUID.
    _knit_sched_backend() { local -n __r=$1; __r='slurm'; }
    _knit_sched_submit() { printf '12345\n'; }

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    local uuid
    uuid="$(_knit_submit --name nightly -- myjob)"

    local jobs_root="${_KNIT_TEST_TMPDIR}/jobs"
    # The alias is a symlink under the job root pointing at the uuid directory.
    [ -L "${jobs_root}/nightly" ]
    [ "$(readlink "${jobs_root}/nightly")" = "${uuid}" ]
    [ -d "${jobs_root}/${uuid}" ]
    [ "$(realpath "${jobs_root}/nightly")" = "$(realpath "${jobs_root}/${uuid}")" ]
    # The name is recorded in the jobs table.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT name FROM jobs WHERE id='${uuid}';")" = "nightly" ]
}

@test "_knit_submit without --name records an empty name and creates no alias" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_without_setup
    knit_done
    _knit_db_setup_table "submit" "jobs"

    _knit_sched_backend() { local -n __r=$1; __r='slurm'; }
    _knit_sched_submit() { printf '12345\n'; }

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    local uuid
    uuid="$(_knit_submit -- myjob)"

    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT name FROM jobs WHERE id='${uuid}';")" = "" ]
    # Only the uuid directory exists under the job root; no extra alias entry.
    local n
    n=$(find "${_KNIT_TEST_TMPDIR}/jobs" -mindepth 1 -maxdepth 1 | wc -l)
    [ "${n}" -eq 1 ]
}

@test "_knit_submit --name fatals on an existing alias" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_without_setup
    knit_done
    _knit_db_setup_table "submit" "jobs"

    _knit_sched_backend() { local -n __r=$1; __r='slurm'; }
    _knit_sched_submit() { printf '12345\n'; }

    # Pre-create the alias so the requested name collides.
    mkdir -p "${_KNIT_TEST_TMPDIR}/jobs"
    ln -s somewhere "${_KNIT_TEST_TMPDIR}/jobs/nightly"

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    run _knit_submit --name nightly -- myjob
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
}

@test "_knit_submit --name rejects an invalid alias" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_without_setup
    knit_done
    _knit_db_setup_table "submit" "jobs"

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    run _knit_submit --name "bad/name" -- myjob
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid name"* ]]
}

@test "_knit_submit bakes absolute paths into the batch script" {
    # The generated batch script cd's into the job dir before re-entering the
    # experiment, so KNIT_SETUP_PREFIX / KNIT_JOB_PREFIX / the cd target must be
    # absolute. A --setup name resolves to <setup-root>/<name>, which is always
    # absolute even when the experiment is entered from a relative directory.
    local setup_dir="${_KNIT_TEST_SETUP_ROOT}/setup"
    mkdir -p "${setup_dir}"
    printf 'mcenv\n' > "${setup_dir}/.setup.type"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_done
    _knit_db_setup_table "submit" "jobs"

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    knit_pushd "${_KNIT_TEST_TMPDIR}"
    _knit_submit --setup "setup" -- myjob
    knit_popd

    local jobscript
    jobscript=$(find "${_KNIT_TEST_TMPDIR}/jobs" -name .job.sh -type f | head -1)
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
    knit_with_setup "mcenv"
    knit_done
    _knit_db_setup_table "submit" "jobs"

    local setup_dir="${_KNIT_TEST_SETUP_ROOT}/setup"
    mkdir -p "${setup_dir}"
    printf 'mcenv\n' > "${setup_dir}/.setup.type"

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    _knit_submit --setup "setup" -- myjob

    local jobscript
    jobscript=$(find "${_KNIT_TEST_TMPDIR}/jobs" -name .job.sh -type f | head -1)
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
    knit_without_setup
    knit_done
    _knit_db_setup_table "submit" "jobs"

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
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
    local setup_dir="${_KNIT_TEST_SETUP_ROOT}/setup"
    mkdir -p "${setup_dir}"
    printf 'mcenv\n' > "${setup_dir}/.setup.type"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_done
    _knit_db_setup_table "submit" "jobs"

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    run _knit_submit --setup "setup" -- myjob
    [ "$status" -eq 0 ]
    [ -d "${_KNIT_TEST_TMPDIR}/jobs" ]
}

@test "_knit_submit rejects a setup built by a different type" {
    local setup_dir="${_KNIT_TEST_SETUP_ROOT}/setup"
    mkdir -p "${setup_dir}"
    printf 'otherenv\n' > "${setup_dir}/.setup.type"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_done

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    run _knit_submit --setup "setup" -- myjob
    [ "$status" -ne 0 ]
    [[ "$output" == *"mcenv"* ]]
    [[ "$output" == *"otherenv"* ]]
}

@test "_knit_submit rejects a setup with no recorded type" {
    local setup_dir="${_KNIT_TEST_SETUP_ROOT}/setup"
    mkdir -p "${setup_dir}"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_done

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    run _knit_submit --setup "setup" -- myjob
    [ "$status" -ne 0 ]
    [[ "$output" == *"no recorded type"* ]]
}

@test "_knit_submit requires --setup when the job declares a setup type" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_with_setup "mcenv"
    knit_done

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    run _knit_submit -- myjob
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a --setup"* ]]
}

@test "_knit_submit runs a setup-less job under jobs/<uuid> without --setup" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_without_setup
    knit_done
    _knit_db_setup_table "submit" "jobs"

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
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
    knit_without_setup
    knit_done
    _knit_db_setup_table "submit" "jobs"

    # Pin the backend and stub the actual submission so no real scheduler (or
    # background job) runs; native_cmd is recorded from the built command.
    _knit_sched_backend() { local -n __r=$1; __r='slurm'; }
    _knit_sched_submit() { printf '12345\n'; }

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    knit_pushd "${_KNIT_TEST_TMPDIR}"
    _knit_submit -- myjob
    knit_popd

    run sqlite3 "${_KNIT_DATABASE}" "SELECT native_cmd FROM jobs;"
    [[ "$output" == "sbatch "*"/.job.sh" ]]
}

# ---------- _knit_submit : default setup adoption ----------

# Materialize a minimal builtin "default" setup at the default path so a
# neither-directive job can adopt it (a real one is instantiated by bootstrap).
_seed_default_setup() {
    local d="${_KNIT_TEST_SETUP_ROOT}/default"
    mkdir -p "${d}"
    printf 'default\n' > "${d}/.setup.type"
    printf 'deadbeef-dead-7ead-8ead-deaddeaddead\n' > "${d}/.setup.id"
    printf '#!/usr/bin/env bash\n' > "${d}/.activate.sh"
}

@test "_knit_submit adopts the default setup for a job with neither directive" {
    _seed_default_setup
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    _knit_db_setup_table "submit" "jobs"

    # Stub dispatch so no real scheduler/background job runs; the batch script we
    # inspect is written before dispatch.
    _knit_sched_backend() { local -n __r=$1; __r='slurm'; }
    _knit_sched_submit() { printf '12345\n'; }

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    _knit_submit -- myjob

    # The job directory lands in the unified job root, and the batch script
    # exports and sources the adopted default setup's .activate.sh.
    local defdir="${_KNIT_TEST_TMPDIR}/setups/default"
    local jobscript
    jobscript=$(find "${_KNIT_TEST_TMPDIR}/jobs" -name .job.sh -type f | head -1)
    [[ -n "${jobscript}" ]]
    grep -q "^export KNIT_SETUP_PREFIX=${defdir}$" "${jobscript}"
    grep -q "^source ${defdir}/.activate.sh$" "${jobscript}"
}

@test "_knit_submit accepts an explicit non-default --setup for a job with neither directive" {
    # A job that declares neither knit_with_setup nor knit_without_setup adopts
    # the default setup only when no --setup is given. Given an explicit --setup,
    # it has no declared type constraint, so any knit-built setup is accepted (no
    # type check against "default").
    local setup_dir="${_KNIT_TEST_SETUP_ROOT}/env"
    mkdir -p "${setup_dir}"
    printf 'env\n' > "${setup_dir}/.setup.type"
    printf '#!/usr/bin/env bash\n' > "${setup_dir}/.activate.sh"
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    _knit_db_setup_table "submit" "jobs"

    # Stub dispatch so no real scheduler/background job runs.
    _knit_sched_backend() { local -n __r=$1; __r='slurm'; }
    _knit_sched_submit() { printf '12345\n'; }

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    run _knit_submit --setup "env" -- myjob
    [ "$status" -eq 0 ]

    # The job runs in the given env setup, not the default: its batch script
    # exports and sources that setup. The job dir itself is in the unified job
    # root, not under the setup.
    [ -d "${_KNIT_TEST_TMPDIR}/jobs" ]
    [ ! -d "${setup_dir}/jobs" ]
    local jobscript
    jobscript=$(find "${_KNIT_TEST_TMPDIR}/jobs" -name .job.sh -type f | head -1)
    [[ -n "${jobscript}" ]]
    grep -q "^export KNIT_SETUP_PREFIX=${setup_dir}$" "${jobscript}"
    grep -q "^source ${setup_dir}/.activate.sh$" "${jobscript}"
}

@test "_knit_submit does not adopt the default setup with knit_without_setup" {
    _seed_default_setup
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_without_setup
    knit_done
    _knit_db_setup_table "submit" "jobs"

    # Stub dispatch so no real scheduler/background job runs.
    _knit_sched_backend() { local -n __r=$1; __r='slurm'; }
    _knit_sched_submit() { printf '12345\n'; }

    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")
    knit_pushd "${_KNIT_TEST_TMPDIR}"
    _knit_submit -- myjob
    knit_popd

    # No setup adopted: the job runs under jobs/<uuid> in the experiment dir and
    # its batch script carries no setup prefix at all.
    [ ! -d "${_KNIT_TEST_TMPDIR}/setups/default/jobs" ]
    local jobscript
    jobscript=$(find "${_KNIT_TEST_TMPDIR}/jobs" -name .job.sh -type f | head -1)
    [[ -n "${jobscript}" ]]
    ! grep -q "KNIT_SETUP_PREFIX" "${jobscript}"
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
    _use_profile polaris
    declare -A r
    _knit_sched_resolve r
    [ "${r[queue]}" = "prod" ]
}

@test "resolve prefers metadata over the profile" {
    _use_profile polaris
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
    _use_profile polaris
    declare -A r
    _knit_sched_resolve r
    [ "${r[cpus-per-node]}" = "32" ]
}

@test "resolve prefers __node_ncpus__ metadata for cpus-per-node" {
    _use_profile polaris
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
    _use_profile polaris
    declare -A r
    # No explicit queue -> profile default queue "prod" (max_walltime 24:00:00)
    _knit_sched_resolve r
    [ "${r[walltime]}" = "24:00:00" ]
}

@test "resolve derives walltime from an explicitly chosen queue's cap" {
    _use_profile polaris
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
    _use_profile polaris
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
    _use_profile polaris
    declare -A r
    r[queue]="debug"       # polaris debug: max_walltime 01:00:00, max_nodes 2
    r[walltime]="02:00:00"
    r[nodes]="1"
    run _knit_sched_validate_caps r
    [ "$status" -ne 0 ]
    [[ "$output" == *"exceeds"* ]]
}

@test "validate_caps passes when walltime is within the queue cap" {
    _use_profile polaris
    declare -A r
    r[queue]="debug"
    r[walltime]="00:30:00"
    r[nodes]="1"
    run _knit_sched_validate_caps r
    [ "$status" -eq 0 ]
}

@test "validate_caps fatals when nodes exceed the queue cap" {
    _use_profile polaris
    declare -A r
    r[queue]="debug"
    r[walltime]="00:10:00"
    r[nodes]="3"           # debug allows at most 2
    run _knit_sched_validate_caps r
    [ "$status" -ne 0 ]
    [[ "$output" == *"exceeds"* ]]
}

@test "validate_caps passes when nodes are within the queue cap" {
    _use_profile polaris
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
    _use_profile polaris
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
    _knit_metadata_get() { local -n __r=$1; __r='none'; }
    local out
    _knit_sched_backend out
    [ "$out" = "none" ]
}

@test "_knit_sched_backend passes slurm/pbs/local metadata through" {
    local out
    _knit_metadata_get() { local -n __r=$1; __r='slurm'; }
    _knit_sched_backend out
    [ "$out" = "slurm" ]
    _knit_metadata_get() { local -n __r=$1; __r='pbs'; }
    _knit_sched_backend out
    [ "$out" = "pbs" ]
    _knit_metadata_get() { local -n __r=$1; __r='local'; }
    _knit_sched_backend out
    [ "$out" = "local" ]
}

@test "_knit_sched_backend maps detection's <unknown> to local when unbootstrapped" {
    _knit_metadata_get() { local -n __r=$1; __r=''; }
    _knit_detect_job_manager() { printf '<unknown>\n'; }
    local out
    _knit_sched_backend out
    [ "$out" = "local" ]
}

@test "_knit_sched_backend uses detection when metadata is empty" {
    _knit_metadata_get() { local -n __r=$1; __r=''; }
    _knit_detect_job_manager() { printf 'slurm\n'; }
    local out
    _knit_sched_backend out
    [ "$out" = "slurm" ]
}
