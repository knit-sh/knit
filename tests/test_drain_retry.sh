#!/usr/bin/env bats

# Unit tests for `submit drain --retry <states>` and `--max-retries`
# (src/drain.sh): at the start of a drain pass, re-queue terminal-failed jobs in
# scope back to "prepared" (reusing the M1 _knit_job_reset_apply worker), then
# drain the prepared backlog. The reset is a one-shot snapshot and honours the
# retry cap.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _KNIT_JQ_EXE="jq"

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    # Point the job root at a temp dir so the reset worker's _knit_job_dir
    # resolves (it removes a stale .job.id there; absent files are harmless).
    _knit_create_metadata_table
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO metadata (key, value) VALUES ('__job_path__', '${_KNIT_TEST_TMPDIR}/jobs');"

    # Ids the DB-driven release stub should mark "failed" (rc 1) instead of
    # "completed" (rc 0) when it releases them. Space-separated, with surrounding
    # spaces so a membership test is a simple substring match.
    _FAIL_IDS=" "

    # Stub the release primitive so the drain loop is DB-driven (no scheduler):
    # claim the oldest prepared job in the --type/--group scope, mark it
    # completed (or failed, per _FAIL_IDS), and print its id. A drained scope
    # yields no id and a non-zero status, exactly as the real primitive signals
    # "queue empty". This makes the retry reset's effect observable: only jobs
    # the reset moved to "prepared" are released.
    _knit_drain_release_next() {
        shift  # drop the wait flag
        local type="" group=""
        while (( $# )); do
            case "$1" in
                --type)  type="$2";  shift 2 ;;
                --group) group="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        local conds="state='prepared'"
        [[ -n "${type}" ]]  && conds="${conds} AND job='${type}'"
        [[ -n "${group}" ]] && conds="${conds} AND \"group\"='${group}'"
        local id
        id="$(sqlite3 "${_KNIT_DATABASE}" \
            "SELECT id FROM jobs WHERE ${conds} ORDER BY id ASC LIMIT 1;")"
        [[ -z "${id}" ]] && return 1
        local newstate="completed" rc=0
        if [[ "${_FAIL_IDS}" == *" ${id} "* ]]; then
            newstate="failed"; rc=1
        fi
        sqlite3 "${_KNIT_DATABASE}" \
            "UPDATE jobs SET state='${newstate}' WHERE id='${id}';"
        printf '%s\n' "${id}"
        return "${rc}"
    }
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

_ensure_jobs_table() {
    sqlite3 "${_KNIT_DATABASE}" \
        "CREATE TABLE IF NOT EXISTS jobs (
            id TEXT, state TEXT, \"group\" TEXT, job TEXT,
            hostnames TEXT, native_cmd TEXT, retries INTEGER);"
}

# _seed <id> <state> [group] [job] [retries]
_seed() {
    local id="$1" state="$2" grp="${3:-g}" job="${4:-myjob}" retries="${5:-0}"
    _ensure_jobs_table
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO jobs (id, state, \"group\", job, hostnames, native_cmd, retries)
         VALUES ('${id}', '${state}', '${grp}', '${job}', 'nodeA', 'sbatch x', ${retries});"
}

_state_of()   { sqlite3 "${_KNIT_DATABASE}" "SELECT state FROM jobs WHERE id='$1';"; }
_retries_of() { sqlite3 "${_KNIT_DATABASE}" "SELECT retries FROM jobs WHERE id='$1';"; }

# ---------- --retry re-queues terminal jobs and drains them ----------

@test "drain --retry killed,failed re-queues and runs killed and failed, not completed" {
    _seed "p1" "prepared"
    _seed "k1" "killed"
    _seed "f1" "failed"
    _seed "c1" "completed"
    run _knit_submit_drain --group g --retry killed,failed
    [ "$status" -eq 0 ]
    # The prepared job and both terminal-failed jobs end completed.
    [ "$(_state_of "p1")" = "completed" ]
    [ "$(_state_of "k1")" = "completed" ]
    [ "$(_state_of "f1")" = "completed" ]
    # The already-completed job was never re-queued (retries untouched).
    [ "$(_state_of "c1")" = "completed" ]
    [ "$(_retries_of "c1")" = "0" ]
    # The retried jobs carry a bumped retries count; the plain prepared one does not.
    [ "$(_retries_of "k1")" = "1" ]
    [ "$(_retries_of "f1")" = "1" ]
    [ "$(_retries_of "p1")" = "0" ]
}

@test "drain --retry killed re-queues only killed, leaving failed terminal" {
    _seed "p1" "prepared"
    _seed "k1" "killed"
    _seed "f1" "failed"
    run _knit_submit_drain --group g --retry killed
    [ "$status" -eq 0 ]
    [ "$(_state_of "p1")" = "completed" ]
    [ "$(_state_of "k1")" = "completed" ]
    [ "$(_state_of "f1")" = "failed" ]
    [ "$(_retries_of "f1")" = "0" ]
}

@test "drain without --retry skips terminal jobs (current behavior)" {
    _seed "p1" "prepared"
    _seed "k1" "killed"
    _seed "f1" "failed"
    run _knit_submit_drain --group g
    [ "$status" -eq 0 ]
    [ "$(_state_of "p1")" = "completed" ]
    [ "$(_state_of "k1")" = "killed" ]
    [ "$(_state_of "f1")" = "failed" ]
}

@test "drain --retry only touches jobs in its own group scope" {
    _seed "a1" "killed" "gA"
    _seed "b1" "killed" "gB"
    run _knit_submit_drain --group gA --retry killed
    [ "$status" -eq 0 ]
    [ "$(_state_of "a1")" = "completed" ]
    # Out-of-scope killed job is left untouched.
    [ "$(_state_of "b1")" = "killed" ]
    [ "$(_retries_of "b1")" = "0" ]
}

# ---------- retry cap ----------

@test "drain --retry --max-retries stops a job at the cap" {
    _seed "hot" "failed" "g" "myjob" "2"
    run _knit_submit_drain --group g --retry failed --max-retries 2
    [ "$status" -eq 0 ]
    # At the cap (2 >= 2): not re-queued, left failed.
    [ "$(_state_of "hot")" = "failed" ]
    [ "$(_retries_of "hot")" = "2" ]
}

@test "drain --retry --max-retries re-queues a job below the cap" {
    _seed "warm" "failed" "g" "myjob" "1"
    run _knit_submit_drain --group g --retry failed --max-retries 2
    [ "$status" -eq 0 ]
    [ "$(_state_of "warm")" = "completed" ]
    [ "$(_retries_of "warm")" = "2" ]
}

# ---------- one-shot snapshot ----------

@test "drain --retry resets once: a job failing again in the pass is not re-reset" {
    _seed "f1" "failed"
    _FAIL_IDS=" f1 "   # the stub re-fails f1 when it releases it
    run _knit_submit_drain --group g --retry failed
    # A released job failed, so drain exits non-zero.
    [ "$status" -ne 0 ]
    # f1 was reset exactly once (retries == 1), ran, failed again, and was NOT
    # re-queued within the same pass: it ends terminal.
    [ "$(_state_of "f1")" = "failed" ]
    [ "$(_retries_of "f1")" = "1" ]
}

# ---------- validation ----------

@test "drain rejects an invalid --retry state" {
    _seed "k1" "killed"
    run _knit_submit_drain --group g --retry running
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid --retry state"* ]]
    [ "$(_state_of "k1")" = "killed" ]
}

@test "drain rejects --retry completed (drain never redoes completed jobs)" {
    _seed "c1" "completed"
    run _knit_submit_drain --group g --retry completed
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid --retry state"* ]]
}

@test "drain rejects a --max-retries below 1" {
    _seed "f1" "failed"
    run _knit_submit_drain --group g --retry failed --max-retries 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"max-retries"* ]]
}

@test "drain --dry-run --retry does not re-queue anything" {
    _seed "k1" "killed"
    run _knit_submit_drain --group g --retry killed --dry-run true
    [ "$status" -eq 0 ]
    # Dry run mutates nothing: the killed job stays killed.
    [ "$(_state_of "k1")" = "killed" ]
}
