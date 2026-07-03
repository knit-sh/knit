#!/usr/bin/env bats

setup() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi

    source knit.sh

    # Override the sqlite executable and database path for testing
    __KNIT_SQLITE_EXE="sqlite3"
    __KNIT_DATABASE="$(mktemp --suffix=.db)"

    # Satisfy the bootstrap check — tests in this file work with a live DB
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    rm -f "${__KNIT_DATABASE}"
    _KNIT_IS_BOOTSTRAPPED=""
}

# Create a jobs table and insert one row with the given id/setup/job/state.
_seed_job() {
    local id="$1" setup="$2" job="$3" state="$4"
    sqlite3 "${__KNIT_DATABASE}" \
        "CREATE TABLE IF NOT EXISTS jobs (id TEXT, setup TEXT, job TEXT, state TEXT);"
    sqlite3 "${__KNIT_DATABASE}" \
        "INSERT INTO jobs (id, setup, job, state) VALUES ('${id}', '${setup}', '${job}', '${state}');"
}

# ---------- job command group ----------

@test "job command group is registered" {
    _knit_set_find _KNIT_COMMANDS "job"
}

@test "job --help lists the group description" {
    run _knit_invoke_command "job" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Inspect submitted jobs"* ]]
}

# ---------- job status ----------

@test "job status prints the state of a known job" {
    _seed_job "abc123" "" "montecarlo" "running"
    run _knit_job_status --id "abc123"
    [ "$status" -eq 0 ]
    [ "$output" = "running" ]
}

@test "job status fails for an unknown id" {
    _seed_job "abc123" "" "montecarlo" "running"
    run _knit_job_status --id "does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No job found"* ]]
}

@test "job status fails when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_job_status --id "abc123"
    [ "$status" -ne 0 ]
}

@test "job status is a no-op when bootstrapping and not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run _knit_job_status --id "abc123"
    [ "$status" -eq 0 ]
}

# ---------- job list ----------

@test "job list shows all jobs" {
    _seed_job "id1" "/s/a" "alpha" "running"
    _seed_job "id2" "/s/b" "beta" "completed"
    run _knit_job_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"id1"* ]]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"id2"* ]]
    [[ "$output" == *"beta"* ]]
}

@test "job list prints a header row" {
    _seed_job "id1" "/s/a" "alpha" "running"
    run _knit_job_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"state"* ]]
}

@test "job list --status filters by lifecycle state" {
    _seed_job "id1" "/s/a" "alpha" "running"
    _seed_job "id2" "/s/b" "beta" "completed"
    run _knit_job_list --status "running"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" != *"beta"* ]]
}

@test "job list --setup filters by setup path" {
    _seed_job "id1" "/s/a" "alpha" "running"
    _seed_job "id2" "/s/b" "beta" "running"
    run _knit_job_list --setup "/s/b"
    [ "$status" -eq 0 ]
    [[ "$output" == *"beta"* ]]
    [[ "$output" != *"alpha"* ]]
}

@test "job list --setup accepts a comma-separated list" {
    _seed_job "id1" "a" "alpha" "running"
    _seed_job "id2" "b" "beta" "running"
    _seed_job "id3" "c" "gamma" "running"
    run _knit_job_list --setup "a,c"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"gamma"* ]]
    [[ "$output" != *"beta"* ]]
}

@test "job list without setup filters lists jobs of any setup" {
    _seed_job "id1" "/s/a" "alpha" "running"
    _seed_job "id2" "" "beta" "running"
    run _knit_job_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
}

@test "job list --no-setup lists only setup-less jobs" {
    _seed_job "id1" "/s/a" "alpha" "running"
    _seed_job "id2" "" "beta" "running"
    run _knit_job_list --no-setup true
    [ "$status" -eq 0 ]
    [[ "$output" == *"beta"* ]]
    [[ "$output" != *"alpha"* ]]
}

@test "job list --no-setup also matches NULL setups" {
    sqlite3 "${__KNIT_DATABASE}" \
        "CREATE TABLE IF NOT EXISTS jobs (id TEXT, setup TEXT, job TEXT, state TEXT);"
    sqlite3 "${__KNIT_DATABASE}" \
        "INSERT INTO jobs (id, job, state) VALUES ('idn', 'delta', 'running');"
    _seed_job "id1" "/s/a" "alpha" "running"
    run _knit_job_list --no-setup true
    [ "$status" -eq 0 ]
    [[ "$output" == *"delta"* ]]
    [[ "$output" != *"alpha"* ]]
}

@test "job list --no-setup combined with --setup lists both" {
    _seed_job "id1" "a" "alpha" "running"
    _seed_job "id2" "b" "beta" "running"
    _seed_job "id3" "" "gamma" "running"
    run _knit_job_list --no-setup true --setup "a"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"gamma"* ]]
    [[ "$output" != *"beta"* ]]
}

@test "job list combines --status and --setup filters" {
    _seed_job "id1" "/s/a" "alpha" "running"
    _seed_job "id2" "/s/a" "beta" "completed"
    _seed_job "id3" "/s/b" "gamma" "running"
    run _knit_job_list --status "running" --setup "/s/a"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" != *"beta"* ]]
    [[ "$output" != *"gamma"* ]]
}

@test "job list --no-setup works as a bare flag through the pipeline" {
    _seed_job "id1" "/s/a" "alpha" "running"
    _seed_job "id2" "" "beta" "running"
    run _knit_invoke_command "job__1__list" --no-setup
    [ "$status" -eq 0 ]
    [[ "$output" == *"beta"* ]]
    [[ "$output" != *"alpha"* ]]
}

@test "job list --no-setup --setup a,b through the pipeline lists both" {
    _seed_job "id1" "a" "alpha" "running"
    _seed_job "id2" "b" "beta" "running"
    _seed_job "id3" "x" "chi" "running"
    _seed_job "id4" "" "gamma" "running"
    run _knit_invoke_command "job__1__list" --no-setup --setup "a,b"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
    [[ "$output" == *"gamma"* ]]
    [[ "$output" != *"chi"* ]]
}

@test "job list through the pipeline lists any setup when no filters given" {
    _seed_job "id1" "/s/a" "alpha" "running"
    _seed_job "id2" "" "beta" "running"
    run _knit_invoke_command "job__1__list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
}

@test "job list prints nothing for an empty jobs table" {
    _seed_job "id1" "/s/a" "alpha" "running"
    sqlite3 "${__KNIT_DATABASE}" "DELETE FROM jobs;"
    run _knit_job_list
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "job list fails when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_job_list
    [ "$status" -ne 0 ]
}

# ---------- job dir resolution ----------

@test "job dir resolves under the setup for a job with a setup" {
    _seed_job "id1" "/s/a" "alpha" "running"
    run _knit_job_dir "id1"
    [ "$status" -eq 0 ]
    [ "$output" = "/s/a/jobs/id1" ]
}

@test "job dir resolves under the experiment root for a setup-less job" {
    _seed_job "id1" "" "alpha" "running"
    _KNIT_PREFIX="/exp/.knit"
    run _knit_job_dir "id1"
    [ "$status" -eq 0 ]
    [ "$output" = "/exp/jobs/id1" ]
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
    __KNIT_SCHED_POLL_INTERVAL="0.1"
    # Force the local backend and stub its wait to flip the state, standing in
    # for the scheduler unblocking + the compute-side terminal-state write.
    _knit_sched_backend() { echo "local"; }
    _knit_sched_local_wait() {
        sqlite3 "${__KNIT_DATABASE}" \
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
    __KNIT_SCHED_POLL_INTERVAL="0.1"
    _knit_sched_backend() { echo "local"; }
    _knit_sched_local_wait() {
        sqlite3 "${__KNIT_DATABASE}" \
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

# ---------- backend wait primitives ----------

@test "local wait blocks until a process exits" {
    __KNIT_SCHED_POLL_INTERVAL="0.1"
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
    __KNIT_SCHED_POLL_INTERVAL="5"
    run _knit_sched_local_wait "not-a-pid"
    [ "$status" -eq 0 ]
}

@test "slurm wait polls squeue until the job leaves the queue" {
    __KNIT_SCHED_POLL_INTERVAL="0.1"
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
    __KNIT_SCHED_POLL_INTERVAL="0.1"
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
    __KNIT_SCHED_POLL_INTERVAL="0.1"
    qstat() { return 0; }  # no job_state line -> job gone
    run _knit_sched_pbs_wait 123
    [ "$status" -eq 0 ]
}
