#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq

    # Absolute path to the built framework, baked into the generated exp.sh for
    # the end-to-end test (the compute-side script cd's away from the repo root).
    KNIT_SH="$(realpath knit.sh)"

    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    _KNIT_TEST_TMPDIR="$(mktemp -d)"

    # Pin the experiment root so a --setup name resolves deterministically under
    # <experiment-root>/setups (the __setup_path__ fallback).
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    _KNIT_TEST_SETUP_ROOT="${_KNIT_TEST_TMPDIR}/setups"

    # Force the local backend regardless of what scheduler happens to be
    # installed on the test host: detection's "<unknown>" degrades to local.
    _KNIT_DETECTED_JOB_MANAGER="<unknown>"

    _knit_create_metadata_table
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    _KNIT_DETECTED_JOB_MANAGER=""
    knit_test_db_teardown
}

# ---------- _knit_sched_local_directives ----------

@test "_knit_sched_local_directives prints nothing" {
    local out
    out="$(_knit_sched_local_directives ignored)"
    [ -z "${out}" ]
}

# ---------- _knit_sched_write_jobscript ----------

@test "write_jobscript emits shebang, prefixes, cd and exec lines" {
    KNIT_SCRIPT_PATH="/fake/exp.sh"
    local jobdir="${_KNIT_TEST_TMPDIR}/jd"
    mkdir -p "${jobdir}"
    declare -A o
    local script="${jobdir}/.job.sh"

    _knit_sched_write_jobscript "${script}" local o \
        "/setups/s1" "${jobdir}" job-uuid-1 submit myjob arg1 arg2

    [ "$(head -n1 "${script}")" = "#!/bin/bash" ]
    grep -Fxq "export KNIT_JOB_PREFIX=${jobdir}" "${script}"
    grep -Fxq "export KNIT_SOURCE_ID=job-uuid-1" "${script}"
    grep -Fxq "export KNIT_SOURCE_COMMAND=submit" "${script}"
    grep -Fxq "export KNIT_SETUP_PREFIX=/setups/s1" "${script}"
    grep -Fxq "export _KNIT_PREFIX=${_KNIT_PREFIX}" "${script}"
    grep -Fxq "cd ${jobdir}" "${script}"
    grep -Fxq "exec /fake/exp.sh submit myjob arg1 arg2" "${script}"
}

@test "write_jobscript omits source exports when source id is empty" {
    KNIT_SCRIPT_PATH="/fake/exp.sh"
    local jobdir="${_KNIT_TEST_TMPDIR}/jd_nosrc"
    mkdir -p "${jobdir}"
    declare -A o
    local script="${jobdir}/.job.sh"

    _knit_sched_write_jobscript "${script}" local o \
        "/setups/s1" "${jobdir}" "" "" myjob

    ! grep -q '^export KNIT_SOURCE_ID=' "${script}"
    ! grep -q '^export KNIT_SOURCE_COMMAND=' "${script}"
}

@test "write_jobscript %q-quotes arguments containing spaces" {
    KNIT_SCRIPT_PATH="/fake/exp.sh"
    local jobdir="${_KNIT_TEST_TMPDIR}/jd2"
    mkdir -p "${jobdir}"
    declare -A o
    local script="${jobdir}/.job.sh"

    _knit_sched_write_jobscript "${script}" local o \
        "/setups/s1" "${jobdir}" job-uuid-2 submit myjob "hello world"

    grep -Fxq 'exec /fake/exp.sh submit myjob hello\ world' "${script}"
}

@test "write_jobscript emits no scheduler directives for the local backend" {
    KNIT_SCRIPT_PATH="/fake/exp.sh"
    local jobdir="${_KNIT_TEST_TMPDIR}/jd3"
    mkdir -p "${jobdir}"
    declare -A o
    local script="${jobdir}/.job.sh"

    _knit_sched_write_jobscript "${script}" local o \
        "/setups/s1" "${jobdir}" job-uuid-3 submit myjob

    ! grep -q '^#SBATCH' "${script}"
    ! grep -q '^#PBS' "${script}"
}

# ---------- _knit_sched_local_submit ----------

@test "local_submit redirects stdout and stderr into the job directory" {
    local jobdir="${_KNIT_TEST_TMPDIR}/run"
    mkdir -p "${jobdir}"
    local script="${jobdir}/run.sh"
    {
        echo '#!/bin/bash'
        echo 'echo to-out'
        echo 'echo to-err >&2'
    } > "${script}"

    declare -A o
    o[wait]="true"
    o[walltime]=""

    _knit_sched_local_submit o "${script}" "${jobdir}"

    grep -Fq "to-out" "${jobdir}/.stdout"
    grep -Fq "to-err" "${jobdir}/.stderr"
}

@test "local_submit forwards walltime and waits when requested" {
    local args="${_KNIT_TEST_TMPDIR}/args"
    local waited="${_KNIT_TEST_TMPDIR}/waited"
    _knit_submit_local() { printf '%s\n' "$*" > "${args}"; printf '4242\n'; }
    _knit_wait_local()   { printf '%s\n' "$1" > "${waited}"; }

    declare -A o
    o[wait]="true"
    o[walltime]="00:10:00"

    local out
    out="$(_knit_sched_local_submit o "/tmp/x/run.sh" "/tmp/x")"

    [ "${out}" = "4242" ]
    grep -Fq -- "--walltime 00:10:00" "${args}"
    grep -Fq -- "--stdout /tmp/x/.stdout" "${args}"
    grep -Fq -- "--stderr /tmp/x/.stderr" "${args}"
    grep -Fq -- "-- bash /tmp/x/run.sh" "${args}"
    [ "$(cat "${waited}")" = "4242" ]
}

@test "local_submit omits walltime and does not wait when not requested" {
    local args="${_KNIT_TEST_TMPDIR}/args2"
    _knit_submit_local() { printf '%s\n' "$*" > "${args}"; printf '7\n'; }
    _knit_wait_local()   { printf 'waited\n' > "${_KNIT_TEST_TMPDIR}/should-not-exist"; }

    declare -A o
    o[wait]="false"
    o[walltime]=""

    _knit_sched_local_submit o "/tmp/x/run.sh" "/tmp/x" >/dev/null

    ! grep -Fq -- "--walltime" "${args}"
    [ ! -f "${_KNIT_TEST_TMPDIR}/should-not-exist" ]
}

# ---------- _knit_submit : full end-to-end ----------

@test "_knit_submit returns the job UUID and records the launcher id" {
    # Stub the launcher so the submission side is exercised end-to-end without
    # spawning a compute-side process (which would need its own bootstrapped
    # experiment). The real compute-side execution is covered by the integration
    # tests.
    _knit_submit_local() { printf '9999\n'; }

    local setup="${_KNIT_TEST_SETUP_ROOT}/setup"
    mkdir -p "${setup}"
    printf 'mcenv\n' > "${setup}/.setup.type"
    KNIT_SCRIPT_PATH="/fake/exp.sh"

    _submit_myjob_fn() { :; }
    knit_register_job "myjob" _submit_myjob_fn "test job"
    knit_with_setup "mcenv"
    knit_done

    # Ensure the jobs table exists so the eager submission record lands
    # (normally created lazily by _knit_invoke_command on first submit).
    _knit_db_setup_table "submit" "jobs"

    # _knit_submit is normally run via _knit_invoke_command; calling it directly
    # here, simulate the executing-command context (both parallel stacks, as the
    # invoker pushes them together) so its knit_output / _knit_set_row_id calls
    # resolve to the "submit" command.
    _KNIT_EXECUTING_COMMAND=("submit")
    _KNIT_EXECUTING_ROW_ID=("$(_knit_resolve_row_id submit)")

    local out
    out="$(_knit_submit --setup "setup" --nodes 2 -- myjob)"

    local jobdir
    jobdir="$(find "${setup}/jobs" -mindepth 1 -maxdepth 1 -type d)"
    [ -n "${jobdir}" ]

    # _knit_submit returns the job UUID (the jobdir basename), not the launcher id.
    [ "${out}" = "$(basename "${jobdir}")" ]
    knit_type_check "uuid" "${out}"

    # The submission is recorded (before dispatch) as a jobs row keyed by
    # the UUID, capturing the job name and initial "submitted" state.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT job FROM jobs WHERE id='${out}';")" = "myjob" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT state FROM jobs WHERE id='${out}';")" = "submitted" ]

    # .job.id holds the implementation-dependent launcher id.
    [ "$(cat "${jobdir}/.job.id")" = "9999" ]
    [ -f "${jobdir}/.job.sh" ]

    # Generated script re-enters the experiment to run the job.
    [ "$(head -n1 "${jobdir}/.job.sh")" = "#!/bin/bash" ]
    grep -Fxq "exec /fake/exp.sh submit myjob" "${jobdir}/.job.sh"
}

# ---------- _knit_sched_local_cancel ----------

@test "_knit_sched_local_cancel signals a running process" {
    local pid
    pid="$(_knit_submit_local -- bash -c 'sleep 5')"
    _knit_sched_local_cancel "${pid}"
    # SIGTERM stops the sleeper; give it a moment, then it must be gone.
    sleep 0.3
    run kill -0 "${pid}"
    [ "$status" -ne 0 ]
}

@test "_knit_sched_local_cancel is a no-op for an already-finished process" {
    local pid
    pid="$(_knit_submit_local -- true)"
    sleep 0.2
    run _knit_sched_local_cancel "${pid}"
    [ "$status" -eq 0 ]
}

@test "_knit_sched_local_cancel is a no-op for a non-numeric pid" {
    run _knit_sched_local_cancel "notapid"
    [ "$status" -eq 0 ]
}
