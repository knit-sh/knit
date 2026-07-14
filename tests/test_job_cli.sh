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

