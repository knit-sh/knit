#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    # _knit_job_dir resolves the job root from __job_path__ metadata against the
    # experiment root (each test pins _KNIT_PREFIX to its own temp dir).
    _knit_create_metadata_table
}

teardown() {
    knit_test_db_teardown
}

# Create a jobs table and insert one row with the given id/setup/job/state.
_seed_job() {
    local id="$1" setup="$2" job="$3" state="$4"
    sqlite3 "${_KNIT_DATABASE}" \
        "CREATE TABLE IF NOT EXISTS jobs (id TEXT, setup TEXT, job TEXT, state TEXT);"
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO jobs (id, setup, job, state) VALUES ('${id}', '${setup}', '${job}', '${state}');"
}

# ---------- job wait ----------

@test "job wait returns 0 for an already-completed job" {
    _seed_job "id1" "" "alpha" "completed"
    run _knit_job_wait --id "id1"
    [ "$status" -eq 0 ]
    [ "$output" = "completed" ]
}

@test "job wait returns non-zero for a killed job" {
    _seed_job "id1" "" "alpha" "killed"
    run _knit_job_wait --id "id1"
    [ "$status" -ne 0 ]
    [ "$output" = "killed" ]
}

@test "job wait fails for an unknown id" {
    _seed_job "id1" "" "alpha" "completed"
    run _knit_job_wait --id "does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No job found"* ]]
}

@test "job wait errors when a running job has no recorded launcher id" {
    _seed_job "id1" "" "alpha" "running"
    _KNIT_PREFIX="$(mktemp -d)/.knit"
    run _knit_job_wait --id "id1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"launcher id"* ]]
}

@test "job wait blocks on the scheduler, then reports the recorded state" {
    _seed_job "id1" "" "alpha" "running"
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    mkdir -p "${root}/jobs/id1"
    echo "999" > "${root}/jobs/id1/.job.id"
    _KNIT_SCHED_POLL_INTERVAL="0.1"
    # Force the local backend and stub its wait to flip the state, standing in
    # for the scheduler unblocking + the compute-side terminal-state write.
    _knit_sched_backend() { local -n __r=$1; __r='local'; }
    _knit_sched_local_wait() {
        sqlite3 "${_KNIT_DATABASE}" \
            "UPDATE jobs SET state = 'completed' WHERE id = 'id1';"
    }
    run _knit_job_wait --id "id1"
    [ "$status" -eq 0 ]
    [ "$output" = "completed" ]
}

@test "job wait returns non-zero when the scheduler wait ends on killed" {
    _seed_job "id1" "" "alpha" "running"
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    mkdir -p "${root}/jobs/id1"
    echo "999" > "${root}/jobs/id1/.job.id"
    _KNIT_SCHED_POLL_INTERVAL="0.1"
    _knit_sched_backend() { local -n __r=$1; __r='local'; }
    _knit_sched_local_wait() {
        sqlite3 "${_KNIT_DATABASE}" \
            "UPDATE jobs SET state = 'killed' WHERE id = 'id1';"
    }
    run _knit_job_wait --id "id1"
    [ "$status" -ne 0 ]
    [ "$output" = "killed" ]
}

@test "job wait is a no-op when bootstrapping and not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run _knit_job_wait --id "id1"
    [ "$status" -eq 0 ]
}

@test "job wait fails when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_job_wait --id "id1"
    [ "$status" -ne 0 ]
}

# ---------- job cancel ----------

@test "job cancel terminates a running job and marks it killed" {
    _seed_job "id1" "" "alpha" "running"
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    mkdir -p "${root}/jobs/id1"
    echo "999" > "${root}/jobs/id1/.job.id"
    # Force the local backend and capture the id handed to its cancel primitive
    # instead of really killing a process.
    _knit_sched_backend() { local -n __r=$1; __r='local'; }
    _knit_sched_local_cancel() { echo "$1" > "${root}/cancelled"; }
    run _knit_job_cancel --id "id1"
    [ "$status" -eq 0 ]
    [ "$(cat "${root}/cancelled")" = "999" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT state FROM jobs WHERE id='id1';")" = "killed" ]
}

@test "job cancel is a no-op for an already-completed job" {
    _seed_job "id1" "" "alpha" "completed"
    run _knit_job_cancel --id "id1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already completed"* ]]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT state FROM jobs WHERE id='id1';")" = "completed" ]
}

@test "job cancel is a no-op for an already-killed job" {
    _seed_job "id1" "" "alpha" "killed"
    run _knit_job_cancel --id "id1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already killed"* ]]
}

@test "job cancel fails for an unknown id" {
    _seed_job "id1" "" "alpha" "running"
    run _knit_job_cancel --id "does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No job found"* ]]
}

@test "job cancel errors when a running job has no recorded launcher id" {
    _seed_job "id1" "" "alpha" "running"
    _KNIT_PREFIX="$(mktemp -d)/.knit"
    run _knit_job_cancel --id "id1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"launcher id"* ]]
    # The state must not have moved: no cancellation actually happened.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT state FROM jobs WHERE id='id1';")" = "running" ]
}

@test "job cancel resolves through the dispatcher" {
    _seed_job "id1" "" "alpha" "running"
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    mkdir -p "${root}/jobs/id1"
    echo "999" > "${root}/jobs/id1/.job.id"
    _knit_sched_backend() { local -n __r=$1; __r='local'; }
    _knit_sched_local_cancel() { :; }
    run _knit_invoke_command "job__1__cancel" --id "id1"
    [ "$status" -eq 0 ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT state FROM jobs WHERE id='id1';")" = "killed" ]
}

@test "job cancel is a no-op when bootstrapping and not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run _knit_job_cancel --id "id1"
    [ "$status" -eq 0 ]
}

@test "job cancel fails when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_job_cancel --id "id1"
    [ "$status" -ne 0 ]
}

# ---------- job rm ----------

@test "job rm removes the directory and row of a terminal job" {
    _seed_job "id1" "" "alpha" "completed"
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    mkdir -p "${root}/jobs/id1"
    touch "${root}/jobs/id1/.stdout"
    run _knit_job_rm --id "id1"
    [ "$status" -eq 0 ]
    [ ! -d "${root}/jobs/id1" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE id='id1';")" = "0" ]
}

@test "job rm removes a job that used a setup" {
    # A job that used a setup still lives in the unified job root, not under the
    # setup: the setup column records the name but no longer affects the location.
    _seed_job "id1" "myenv" "alpha" "killed"
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    mkdir -p "${root}/jobs/id1"
    run _knit_job_rm --id "id1"
    [ "$status" -eq 0 ]
    [ ! -d "${root}/jobs/id1" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE id='id1';")" = "0" ]
}

@test "job rm refuses a running job without --force" {
    _seed_job "id1" "" "alpha" "running"
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    mkdir -p "${root}/jobs/id1"
    run _knit_job_rm --id "id1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"still running"* ]]
    # Neither the directory nor the row must have been touched.
    [ -d "${root}/jobs/id1" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE id='id1';")" = "1" ]
}

@test "job rm removes a running job with --force" {
    _seed_job "id1" "" "alpha" "running"
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    mkdir -p "${root}/jobs/id1"
    run _knit_job_rm --id "id1" --force true
    [ "$status" -eq 0 ]
    [ ! -d "${root}/jobs/id1" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE id='id1';")" = "0" ]
}

@test "job rm fails for an unknown id" {
    _seed_job "id1" "" "alpha" "completed"
    run _knit_job_rm --id "does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No job found"* ]]
}

@test "job rm resolves through the dispatcher" {
    _seed_job "id1" "" "alpha" "completed"
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    mkdir -p "${root}/jobs/id1"
    run _knit_invoke_command "job__1__rm" --id "id1"
    [ "$status" -eq 0 ]
    [ ! -d "${root}/jobs/id1" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE id='id1';")" = "0" ]
}

@test "job rm --force works as a bare flag through the pipeline" {
    _seed_job "id1" "" "alpha" "running"
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    mkdir -p "${root}/jobs/id1"
    run _knit_invoke_command "job__1__rm" --id "id1" --force
    [ "$status" -eq 0 ]
    [ ! -d "${root}/jobs/id1" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE id='id1';")" = "0" ]
}

@test "job rm is a no-op when bootstrapping and not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run _knit_job_rm --id "id1"
    [ "$status" -eq 0 ]
}

@test "job rm fails when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_job_rm --id "id1"
    [ "$status" -ne 0 ]
}

# ---------- backend wait primitives ----------

@test "local wait blocks until a process exits" {
    _KNIT_SCHED_POLL_INTERVAL="0.1"
    sleep 0.4 &
    local pid=$!
    local start end
    start=$(date +%s)
    run _knit_sched_local_wait "${pid}"
    end=$(date +%s)
    [ "$status" -eq 0 ]
    # Should have blocked at least until the process finished.
    [ "$(( end - start ))" -ge 0 ]
    ! kill -0 "${pid}" 2>/dev/null
}

@test "local wait returns immediately for a non-numeric id" {
    _KNIT_SCHED_POLL_INTERVAL="5"
    run _knit_sched_local_wait "not-a-pid"
    [ "$status" -eq 0 ]
}

@test "slurm wait polls squeue until the job leaves the queue" {
    _KNIT_SCHED_POLL_INTERVAL="0.1"
    local counter
    counter="$(mktemp)"
    echo 0 > "${counter}"
    # Fake squeue: report the job present for two polls, then gone (empty).
    squeue() {
        local n
        n=$(cat "${counter}")
        n=$(( n + 1 ))
        echo "${n}" > "${counter}"
        [[ "${n}" -le 2 ]] && printf 'RUNNING\n'
        return 0
    }
    run _knit_sched_slurm_wait 123
    [ "$status" -eq 0 ]
    [ "$(cat "${counter}")" -ge 3 ]
    rm -f "${counter}"
}

@test "pbs wait polls qstat until the job reaches a terminal state" {
    _KNIT_SCHED_POLL_INTERVAL="0.1"
    local counter
    counter="$(mktemp)"
    echo 0 > "${counter}"
    # Fake qstat: running for two polls, then exiting (E), which is terminal.
    qstat() {
        local n
        n=$(cat "${counter}")
        n=$(( n + 1 ))
        echo "${n}" > "${counter}"
        if [[ "${n}" -le 2 ]]; then
            printf '    job_state = R\n'
        else
            printf '    job_state = E\n'
        fi
    }
    run _knit_sched_pbs_wait 123
    [ "$status" -eq 0 ]
    [ "$(cat "${counter}")" -ge 3 ]
    rm -f "${counter}"
}

@test "pbs wait treats an unknown job as finished" {
    _KNIT_SCHED_POLL_INTERVAL="0.1"
    qstat() { return 0; }  # no job_state line -> job gone
    run _knit_sched_pbs_wait 123
    [ "$status" -eq 0 ]
}

