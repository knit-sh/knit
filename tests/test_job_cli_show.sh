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

@test "job show stdout resolves the job dir in the unified job root for a job with a setup" {
    # The setup column records the setup name but no longer affects the job dir:
    # a job that used a setup still lives at <job-root>/<id>.
    local root
    root="$(mktemp -d)"
    _KNIT_PREFIX="${root}/.knit"
    _seed_job "abc123" "myenv" "montecarlo" "completed"
    mkdir -p "${root}/jobs/abc123"
    printf 'from setup\n' > "${root}/jobs/abc123/.stdout"
    run _knit_job_show_stdout --id "abc123"
    rm -rf "${root}"
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
