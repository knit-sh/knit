#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
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
    sqlite3 "${_KNIT_DATABASE}" \
        "CREATE TABLE IF NOT EXISTS jobs (id TEXT, setup TEXT, job TEXT, state TEXT);"
    sqlite3 "${_KNIT_DATABASE}" \
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
    sqlite3 "${_KNIT_DATABASE}" "DELETE FROM jobs;"
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

# ---------- job list --types ----------

@test "job list --types filters by a single job type" {
    _seed_job "id1" "" "alpha" "running"
    _seed_job "id2" "" "beta" "running"
    run _knit_job_list --types "alpha"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" != *"beta"* ]]
}

@test "job list --types accepts a comma-separated list" {
    _seed_job "id1" "" "alpha" "running"
    _seed_job "id2" "" "beta" "running"
    _seed_job "id3" "" "gamma" "running"
    run _knit_job_list --types "alpha,gamma"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"gamma"* ]]
    [[ "$output" != *"beta"* ]]
}

@test "job list combines --types with --status" {
    _seed_job "id1" "" "alpha" "running"
    _seed_job "id2" "" "alpha" "completed"
    _seed_job "id3" "" "beta" "running"
    run _knit_job_list --types "alpha" --status "running"
    [ "$status" -eq 0 ]
    [[ "$output" == *"id1"* ]]
    [[ "$output" != *"id2"* ]]
    [[ "$output" != *"beta"* ]]
}

@test "job list combines --types with --setup" {
    _seed_job "id1" "a" "alpha" "running"
    _seed_job "id2" "b" "alpha" "running"
    _seed_job "id3" "a" "beta" "running"
    run _knit_job_list --types "alpha" --setup "a"
    [ "$status" -eq 0 ]
    [[ "$output" == *"id1"* ]]
    [[ "$output" != *"id2"* ]]
    [[ "$output" != *"id3"* ]]
}

@test "job list --types matches nothing when no job has the type" {
    _seed_job "id1" "" "alpha" "running"
    run _knit_job_list --types "nosuchtype"
    [ "$status" -eq 0 ]
    [[ "$output" != *"alpha"* ]]
}

@test "job list --json applies the --types filter" {
    command -v jq &>/dev/null || skip "jq not available"
    _seed_job "id1" "" "alpha" "running"
    _seed_job "id2" "" "beta" "running"
    _seed_job "id3" "" "gamma" "running"
    run _knit_job_list --json true --types "alpha,gamma"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '. | map(.job) == ["alpha","gamma"]' >/dev/null
}

# ---------- job list --json ----------

@test "job list --json emits a valid JSON array of jobs" {
    command -v jq &>/dev/null || skip "jq not available"
    _seed_job "id1" "/s/a" "alpha" "running"
    _seed_job "id2" "/s/b" "beta" "completed"
    run _knit_job_list --json true
    [ "$status" -eq 0 ]
    # Parses as JSON and holds both jobs.
    echo "$output" | jq -e '. | length == 2' >/dev/null
    echo "$output" | jq -e '.[0].id == "id1" and .[0].job == "alpha" and .[0].state == "running"' >/dev/null
    echo "$output" | jq -e '.[1].id == "id2"' >/dev/null
}

@test "job list --json emits [] for an empty jobs table" {
    command -v jq &>/dev/null || skip "jq not available"
    _seed_job "id1" "/s/a" "alpha" "running"
    sqlite3 "${_KNIT_DATABASE}" "DELETE FROM jobs;"
    run _knit_job_list --json true
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
    echo "$output" | jq -e '. == []' >/dev/null
}

@test "job list --json applies the --status filter" {
    command -v jq &>/dev/null || skip "jq not available"
    _seed_job "id1" "/s/a" "alpha" "running"
    _seed_job "id2" "/s/b" "beta" "completed"
    run _knit_job_list --json true --status "running"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '. | length == 1' >/dev/null
    echo "$output" | jq -e '.[0].id == "id1"' >/dev/null
}

@test "job list --json applies the --setup filter" {
    command -v jq &>/dev/null || skip "jq not available"
    _seed_job "id1" "a" "alpha" "running"
    _seed_job "id2" "b" "beta" "running"
    _seed_job "id3" "c" "gamma" "running"
    run _knit_job_list --json true --setup "a,c"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '. | map(.id) == ["id1","id3"]' >/dev/null
}

@test "job list --json works as a bare flag through the pipeline" {
    command -v jq &>/dev/null || skip "jq not available"
    _seed_job "id1" "/s/a" "alpha" "running"
    _seed_job "id2" "/s/b" "beta" "completed"
    run _knit_invoke_command "job__1__list" --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '. | length == 2' >/dev/null
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
    _KNIT_SCHED_POLL_INTERVAL="0.1"
    # Force the local backend and stub its wait to flip the state, standing in
    # for the scheduler unblocking + the compute-side terminal-state write.
    _knit_sched_backend() { echo "local"; }
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
    _knit_sched_backend() { echo "local"; }
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
    _knit_sched_backend() { echo "local"; }
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
    _knit_sched_backend() { echo "local"; }
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
    local setup
    setup="$(mktemp -d)"
    _seed_job "id1" "${setup}" "alpha" "killed"
    mkdir -p "${setup}/jobs/id1"
    run _knit_job_rm --id "id1"
    [ "$status" -eq 0 ]
    [ ! -d "${setup}/jobs/id1" ]
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

# ---------- job show ----------

# Create a per-job parameter table named after the job and insert one row.
_seed_params() {
    local table="$1" id="$2" samples="$3"
    sqlite3 "${_KNIT_DATABASE}" \
        "CREATE TABLE IF NOT EXISTS \"${table}\" (id TEXT, samples TEXT);"
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO \"${table}\" (id, samples) VALUES ('${id}', '${samples}');"
}

@test "job show prints a submission and a parameters section" {
    _seed_job "abc123" "/exp/env" "montecarlo" "completed"
    _seed_params "montecarlo" "abc123" "1000"
    run _knit_job_show --id "abc123"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Submission:"* ]]
    [[ "$output" == *"Parameters:"* ]]
    # The submission section shows the state column, the parameters the samples.
    [[ "$output" == *"completed"* ]]
    [[ "$output" == *"1000"* ]]
}

@test "job show works when the per-job table does not exist yet" {
    _seed_job "abc123" "" "montecarlo" "submitted"
    run _knit_job_show --id "abc123"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Submission:"* ]]
    [[ "$output" == *"submitted"* ]]
    [[ "$output" == *"Parameters:"* ]]
}

@test "job show fails for an unknown id" {
    _seed_job "abc123" "" "montecarlo" "running"
    run _knit_job_show --id "does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No job found"* ]]
}

@test "job show --json emits a submission and parameters object" {
    command -v jq &>/dev/null || skip "jq not available"
    _KNIT_JQ_EXE="jq"
    _seed_job "abc123" "/exp/env" "montecarlo" "completed"
    _seed_params "montecarlo" "abc123" "1000"
    run _knit_job_show --id "abc123" --json true
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.submission.state')" = "completed" ]
    [ "$(echo "$output" | jq -r '.submission.job')" = "montecarlo" ]
    [ "$(echo "$output" | jq -r '.parameters.samples')" = "1000" ]
}

@test "job show --json yields null parameters when the job has not run" {
    command -v jq &>/dev/null || skip "jq not available"
    _KNIT_JQ_EXE="jq"
    _seed_job "abc123" "" "montecarlo" "submitted"
    run _knit_job_show --id "abc123" --json true
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.submission.state')" = "submitted" ]
    [ "$(echo "$output" | jq -r '.parameters')" = "null" ]
}

@test "job show --json works as a bare flag through the pipeline" {
    command -v jq &>/dev/null || skip "jq not available"
    _KNIT_JQ_EXE="jq"
    _seed_job "abc123" "/exp/env" "montecarlo" "completed"
    _seed_params "montecarlo" "abc123" "1000"
    run _knit_invoke_command "job__1__show" --id "abc123" --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.submission.job')" = "montecarlo" ]
    [ "$(echo "$output" | jq -r '.parameters.samples')" = "1000" ]
}

@test "job show fails when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_job_show --id "abc123"
    [ "$status" -ne 0 ]
}

@test "job show is a no-op when bootstrapping and not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run _knit_job_show --id "abc123"
    [ "$status" -eq 0 ]
}

# ---------- job show stdout / stderr ----------

@test "job show stdout prints the captured standard output" {
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    printf 'hello stdout\n' > "${root}/jobs/abc123/.stdout"
    run _knit_job_show_stdout --id "abc123"
    rm -rf "${root}"
    [ "$status" -eq 0 ]
    [ "$output" = "hello stdout" ]
}

@test "job show stderr prints the captured standard error" {
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    printf 'boom stderr\n' > "${root}/jobs/abc123/.stderr"
    run _knit_job_show_stderr --id "abc123"
    rm -rf "${root}"
    [ "$status" -eq 0 ]
    [ "$output" = "boom stderr" ]
}

@test "job show stdout resolves the job dir under the setup" {
    local setup
    setup="$(mktemp -d)"
    _seed_job "abc123" "${setup}" "montecarlo" "completed"
    mkdir -p "${setup}/jobs/abc123"
    printf 'from setup\n' > "${setup}/jobs/abc123/.stdout"
    run _knit_job_show_stdout --id "abc123"
    rm -rf "${setup}"
    [ "$status" -eq 0 ]
    [ "$output" = "from setup" ]
}

@test "job show stdout fails for an unknown id" {
    _seed_job "abc123" "" "montecarlo" "completed"
    run _knit_job_show_stdout --id "nope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No job found"* ]]
}

@test "job show stdout fails when the stdout file is missing" {
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    run _knit_job_show_stdout --id "abc123"
    rm -rf "${root}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No stdout recorded"* ]]
}

@test "job show stderr fails when the stderr file is missing" {
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    run _knit_job_show_stderr --id "abc123"
    rm -rf "${root}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No stderr recorded"* ]]
}

@test "job show stdout resolves through the dispatcher" {
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    printf 'dispatched\n' > "${root}/jobs/abc123/.stdout"
    run _knit_invoke_command "job__1__show__1__stdout" --id "abc123"
    rm -rf "${root}"
    [ "$status" -eq 0 ]
    [ "$output" = "dispatched" ]
}

@test "job show stdout fails when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_job_show_stdout --id "abc123"
    [ "$status" -ne 0 ]
}

@test "job show stdout is a no-op when bootstrapping and not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run _knit_job_show_stdout --id "abc123"
    [ "$status" -eq 0 ]
}

# ---------- job show script ----------

@test "job show script prints the generated batch script" {
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    printf '#!/bin/bash\necho run\n' > "${root}/jobs/abc123/.job.sh"
    run _knit_job_show_script --id "abc123"
    rm -rf "${root}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"#!/bin/bash"* ]]
    [[ "$output" == *"echo run"* ]]
}

@test "job show script fails for an unknown id" {
    _seed_job "abc123" "" "montecarlo" "completed"
    run _knit_job_show_script --id "nope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No job found"* ]]
}

@test "job show script fails when the script file is missing" {
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    run _knit_job_show_script --id "abc123"
    rm -rf "${root}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No script recorded"* ]]
}

@test "job show script resolves through the dispatcher" {
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    printf '#!/bin/bash\nscript body\n' > "${root}/jobs/abc123/.job.sh"
    run _knit_invoke_command "job__1__show__1__script" --id "abc123"
    rm -rf "${root}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"script body"* ]]
}

@test "job show script fails when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_job_show_script --id "abc123"
    [ "$status" -ne 0 ]
}

@test "job show script is a no-op when bootstrapping and not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run _knit_job_show_script --id "abc123"
    [ "$status" -eq 0 ]
}

# ---------- job show --follow ----------

@test "_knit_job_state_is_terminal recognizes terminal and non-terminal states" {
    _seed_job "done" "" "montecarlo" "completed"
    _seed_job "gone" "" "montecarlo" "killed"
    _seed_job "live" "" "montecarlo" "running"
    _knit_job_state_is_terminal "done"
    _knit_job_state_is_terminal "gone"
    run _knit_job_state_is_terminal "live"
    [ "$status" -ne 0 ]
    run _knit_job_state_is_terminal "nope"
    [ "$status" -ne 0 ]
}

@test "job show stdout --follow prints and exits on an already-finished job" {
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    printf 'final output\n' > "${root}/jobs/abc123/.stdout"
    run _knit_job_show_stdout --id "abc123" --follow true
    rm -rf "${root}"
    [ "$status" -eq 0 ]
    [ "$output" = "final output" ]
}

@test "job show stderr --follow prints and exits on an already-finished job" {
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    printf 'final error\n' > "${root}/jobs/abc123/.stderr"
    run _knit_job_show_stderr --id "abc123" --follow true
    rm -rf "${root}"
    [ "$status" -eq 0 ]
    [ "$output" = "final error" ]
}

@test "job show stdout --follow errors on a finished job with no output" {
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    run _knit_job_show_stdout --id "abc123" --follow true
    rm -rf "${root}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No stdout recorded"* ]]
}

@test "job show stdout --follow fails for an unknown id" {
    _seed_job "abc123" "" "montecarlo" "running"
    run _knit_job_show_stdout --id "nope" --follow true
    [ "$status" -ne 0 ]
    [[ "$output" == *"No job found"* ]]
}

@test "job show stdout --follow streams a running job and stops when it finishes" {
    local root cf
    root="$(mktemp -d)"
    cf="$(mktemp)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "running"
    mkdir -p "${root}/jobs/abc123"
    printf 'streamed line\n' > "${root}/jobs/abc123/.stdout"
    _KNIT_SCHED_POLL_INTERVAL="0.1"
    # Report running for the initial check, then terminal so the follow loop ends.
    _knit_job_state_is_terminal() {
        local n
        n="$(cat "${cf}" 2>/dev/null || echo 0)"
        n=$((n + 1))
        printf '%s' "${n}" > "${cf}"
        [[ "${n}" -ge 2 ]]
    }
    run _knit_job_show_stdout --id "abc123" --follow true
    rm -rf "${root}" "${cf}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"streamed line"* ]]
}

@test "job show stdout --follow waits for the output file to appear" {
    local root cf
    root="$(mktemp -d)"
    cf="$(mktemp)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "running"
    mkdir -p "${root}/jobs/abc123"
    _KNIT_SCHED_POLL_INTERVAL="0.1"
    # Stay non-terminal for the first checks (top check + one wait-loop pass +
    # one follow-loop pass), then terminal.
    _knit_job_state_is_terminal() {
        local n
        n="$(cat "${cf}" 2>/dev/null || echo 0)"
        n=$((n + 1))
        printf '%s' "${n}" > "${cf}"
        [[ "${n}" -ge 4 ]]
    }
    # The file appears shortly after the follow starts waiting for it.
    ( sleep 0.05; printf 'late line\n' > "${root}/jobs/abc123/.stdout" ) &
    run _knit_job_show_stdout --id "abc123" --follow true
    wait
    rm -rf "${root}" "${cf}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"late line"* ]]
}

@test "job show stdout --follow errors if a running job finishes without output" {
    local root cf
    root="$(mktemp -d)"
    cf="$(mktemp)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "running"
    mkdir -p "${root}/jobs/abc123"
    _KNIT_SCHED_POLL_INTERVAL="0.1"
    # Non-terminal for the top check, then terminal while still waiting for the
    # file that never appears.
    _knit_job_state_is_terminal() {
        local n
        n="$(cat "${cf}" 2>/dev/null || echo 0)"
        n=$((n + 1))
        printf '%s' "${n}" > "${cf}"
        [[ "${n}" -ge 2 ]]
    }
    run _knit_job_show_stdout --id "abc123" --follow true
    rm -rf "${root}" "${cf}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No stdout recorded"* ]]
}

@test "job show stdout --follow works as a bare flag through the pipeline" {
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    printf 'piped follow\n' > "${root}/jobs/abc123/.stdout"
    run _knit_invoke_command "job__1__show__1__stdout" --id "abc123" --follow
    rm -rf "${root}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"piped follow"* ]]
}

# ---------- job resubmit ----------

# Register a montecarlo job so its parameter schema (and its per-job table)
# exist, mirroring what an experiment script would declare.
_register_mc_job() {
    knit_register_job "montecarlo" _mc_job_fn "Estimate pi as a job."
    knit_with_optional "samples:integer" "100" "Number of samples."
    _mc_job_fn() { :; }
    knit_done
}

@test "job resubmit invokes submit with the recorded setup, job and params" {
    _register_mc_job
    _seed_job "id1" "/exp/env" "montecarlo" "completed"
    _seed_params "montecarlo" "id1" "1000"
    # Capture the submit invocation instead of really submitting.
    _knit_invoke_command() { printf 'INVOKE: %s\n' "$*"; }
    run _knit_job_resubmit --id "id1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INVOKE: submit "* ]]
    [[ "$output" == *"--setup /exp/env"* ]]
    [[ "$output" == *"-- montecarlo"* ]]
    [[ "$output" == *"--samples 1000"* ]]
}

@test "job resubmit omits --setup for a setup-less job" {
    _register_mc_job
    _seed_job "id1" "" "montecarlo" "completed"
    _seed_params "montecarlo" "id1" "1000"
    _knit_invoke_command() { printf 'INVOKE: %s\n' "$*"; }
    run _knit_job_resubmit --id "id1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"-- montecarlo"* ]]
    [[ "$output" == *"--samples 1000"* ]]
    [[ "$output" != *"--setup"* ]]
}

@test "job resubmit uses submission options only when the job never ran" {
    _register_mc_job
    # A job that was submitted but never ran has an empty per-job table.
    _seed_job "id1" "/exp/env" "montecarlo" "submitted"
    _knit_invoke_command() { printf 'INVOKE: %s\n' "$*"; }
    run _knit_job_resubmit --id "id1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--setup /exp/env"* ]]
    [[ "$output" == *"-- montecarlo"* ]]
    [[ "$output" != *"--samples"* ]]
}

@test "job resubmit replays a recorded submission flag" {
    _register_mc_job
    # Seed a jobs table that carries the "wait" flag column set to true.
    sqlite3 "${_KNIT_DATABASE}" \
        "CREATE TABLE jobs (id TEXT, setup TEXT, wait TEXT, job TEXT, state TEXT);"
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO jobs (id, setup, wait, job, state) VALUES ('id1', '', 'true', 'montecarlo', 'completed');"
    _knit_invoke_command() { printf 'INVOKE: %s\n' "$*"; }
    run _knit_job_resubmit --id "id1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--wait"* ]]
}

@test "job resubmit fails for an unknown id" {
    _register_mc_job
    _seed_job "id1" "" "montecarlo" "completed"
    _knit_invoke_command() { printf 'INVOKE: %s\n' "$*"; }
    run _knit_job_resubmit --id "does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No job found"* ]]
}

@test "job resubmit resolves through the dispatcher" {
    _register_mc_job
    _seed_job "id1" "" "montecarlo" "completed"
    _seed_params "montecarlo" "id1" "1000"
    # Stub the submit entry point so the real scheduler is never contacted.
    _knit_submit() { printf 'SUBMITTED %s\n' "$*"; }
    run _knit_invoke_command "job__1__resubmit" --id "id1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resubmitting job"* ]]
}

@test "job resubmit is a no-op when bootstrapping and not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run _knit_job_resubmit --id "id1"
    [ "$status" -eq 0 ]
}

@test "job resubmit fails when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_job_resubmit --id "id1"
    [ "$status" -ne 0 ]
}
