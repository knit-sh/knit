#!/usr/bin/env bats

# Unit tests for `knit job reset` (src/job_cli.sh): re-queue terminal-failed
# jobs (killed / failed) back to "prepared" so a later drain retries them. The
# worker clears the previous run's artifacts, increments the "retries" counter,
# and never touches non-terminal states; a retry cap and the id / group / type
# selectors narrow which jobs are reset.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    _KNIT_TEST_TMPDIR="$(mktemp -d)"

    # Point the job root at a temp dir so _knit_job_dir resolves to a writable
    # path: job reset reads/removes <jobdir>/.job.id there. An absolute
    # __job_path__ is returned verbatim by _knit_resolve_experiment_path.
    _knit_create_metadata_table
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO metadata (key, value) VALUES ('__job_path__', '${_KNIT_TEST_TMPDIR}/jobs');"
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

# Create the jobs table (only the columns the reset worker reads or writes) once.
_ensure_jobs_table() {
    sqlite3 "${_KNIT_DATABASE}" \
        "CREATE TABLE IF NOT EXISTS jobs (
            id TEXT, state TEXT, \"group\" TEXT, job TEXT,
            hostnames TEXT, native_cmd TEXT, retries INTEGER);"
}

# Seed one job row and a job directory holding a stale .job.id.
#   _seed <id> <state> [group] [job] [retries]
_seed() {
    local id="$1" state="$2" grp="${3:-}" job="${4:-myjob}" retries="${5:-0}"
    _ensure_jobs_table
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO jobs (id, state, \"group\", job, hostnames, native_cmd, retries)
         VALUES ('${id}', '${state}', '${grp}', '${job}', 'nodeA,nodeB', 'sbatch x', ${retries});"
    local jobdir
    jobdir="$(_knit_job_dir "${id}")"
    mkdir -p "${jobdir}"
    printf '1234\n' > "${jobdir}/.job.id"
}

_state_of()     { sqlite3 "${_KNIT_DATABASE}" "SELECT state FROM jobs WHERE id='$1';"; }
_retries_of()   { sqlite3 "${_KNIT_DATABASE}" "SELECT retries FROM jobs WHERE id='$1';"; }
_hostnames_of() { sqlite3 "${_KNIT_DATABASE}" "SELECT hostnames FROM jobs WHERE id='$1';"; }
_nativecmd_of() { sqlite3 "${_KNIT_DATABASE}" "SELECT native_cmd FROM jobs WHERE id='$1';"; }
_has_job_id()   { [[ -f "$(_knit_job_dir "$1")/.job.id" ]]; }

# ---------- resetting terminal-failed jobs ----------

@test "job reset moves a killed job back to prepared" {
    _seed "k1" "killed"
    run _knit_job_reset --id "k1"
    [ "$status" -eq 0 ]
    [ "$(_state_of "k1")" = "prepared" ]
    [[ "$output" == *"k1"* ]]
}

@test "job reset moves a failed job back to prepared" {
    _seed "f1" "failed"
    run _knit_job_reset --id "f1"
    [ "$status" -eq 0 ]
    [ "$(_state_of "f1")" = "prepared" ]
}

@test "job reset clears hostnames, native-cmd, and .job.id and bumps retries" {
    _seed "k1" "killed" "" "myjob" "0"
    _has_job_id "k1"
    run _knit_job_reset --id "k1"
    [ "$status" -eq 0 ]
    [ "$(_hostnames_of "k1")" = "" ]
    [ "$(_nativecmd_of "k1")" = "" ]
    [ "$(_retries_of "k1")" = "1" ]
    ! _has_job_id "k1"
}

@test "job reset coalesces a NULL retries count to 0 before bumping" {
    _ensure_jobs_table
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO jobs (id, state, job) VALUES ('n1', 'failed', 'myjob');"
    run _knit_job_reset --id "n1"
    [ "$status" -eq 0 ]
    [ "$(_retries_of "n1")" = "1" ]
}

# ---------- states it must not touch ----------

@test "job reset leaves a completed job alone by default" {
    _seed "c1" "completed"
    run _knit_job_reset --id "c1"
    [ "$status" -eq 0 ]
    [ "$(_state_of "c1")" = "completed" ]
    [ "$(_retries_of "c1")" = "0" ]
}

@test "job reset --force --state completed resets a completed job" {
    _seed "c1" "completed"
    run _knit_job_reset --id "c1" --state completed --force true
    [ "$status" -eq 0 ]
    [ "$(_state_of "c1")" = "prepared" ]
}

@test "job reset never touches a running job" {
    _seed "r1" "running"
    run _knit_job_reset --id "r1"
    [ "$status" -eq 0 ]
    [ "$(_state_of "r1")" = "running" ]
}

@test "job reset never touches a submitting job" {
    _seed "s1" "submitting"
    run _knit_job_reset --id "s1"
    [ "$status" -eq 0 ]
    [ "$(_state_of "s1")" = "submitting" ]
}

# ---------- selectors ----------

@test "job reset --group resets only the matching group" {
    _seed "a1" "killed" "gA"
    _seed "b1" "killed" "gB"
    run _knit_job_reset --group "gA"
    [ "$status" -eq 0 ]
    [ "$(_state_of "a1")" = "prepared" ]
    [ "$(_state_of "b1")" = "killed" ]
}

@test "job reset --type resets only the matching job type" {
    _seed "a1" "failed" "" "alpha"
    _seed "b1" "failed" "" "beta"
    run _knit_job_reset --type "alpha"
    [ "$status" -eq 0 ]
    [ "$(_state_of "a1")" = "prepared" ]
    [ "$(_state_of "b1")" = "failed" ]
}

@test "job reset --id resets only that job" {
    _seed "a1" "killed"
    _seed "b1" "killed"
    run _knit_job_reset --id "a1"
    [ "$status" -eq 0 ]
    [ "$(_state_of "a1")" = "prepared" ]
    [ "$(_state_of "b1")" = "killed" ]
}

@test "job reset --state killed re-queues only killed, not failed" {
    _seed "k1" "killed"
    _seed "f1" "failed"
    run _knit_job_reset --state killed
    [ "$status" -eq 0 ]
    [ "$(_state_of "k1")" = "prepared" ]
    [ "$(_state_of "f1")" = "failed" ]
}

# ---------- retry cap ----------

@test "job reset --max-retries skips a job at the cap and resets one below it" {
    _seed "hot" "failed" "" "myjob" "3"
    _seed "ok"  "failed" "" "myjob" "1"
    run _knit_job_reset --max-retries 3
    [ "$status" -eq 0 ]
    # "hot" is at the cap (3 >= 3): left terminal, with a warning.
    [ "$(_state_of "hot")" = "failed" ]
    [ "$(_retries_of "hot")" = "3" ]
    [[ "$output" == *"cap"* ]]
    # "ok" is below the cap: reset and bumped.
    [ "$(_state_of "ok")" = "prepared" ]
    [ "$(_retries_of "ok")" = "2" ]
}

# ---------- validation ----------

@test "job reset rejects an unknown --state value" {
    _seed "k1" "killed"
    run _knit_job_reset --state running
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid --state"* ]]
    [ "$(_state_of "k1")" = "killed" ]
}

@test "job reset rejects --state completed without --force" {
    _seed "c1" "completed"
    run _knit_job_reset --state completed
    [ "$status" -ne 0 ]
    [[ "$output" == *"--force"* ]]
    [ "$(_state_of "c1")" = "completed" ]
}

@test "job reset rejects a --max-retries below 1" {
    _seed "k1" "killed"
    run _knit_job_reset --max-retries 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"max-retries"* ]]
}

# ---------- idempotence ----------

@test "job reset reports zero when nothing matches" {
    _seed "c1" "completed"
    run _knit_job_reset --group "no-such-group"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reset 0 job(s)"* ]]
}

@test "job reset is registered under the job command group" {
    _knit_job_discover
    _knit_set_find _KNIT_COMMANDS "job__1__reset"
}
