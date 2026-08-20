#!/usr/bin/env bats

# Unit tests for the `prepare` dispatcher (src/prepare.sh) and the --group option
# shared with `submit`. prepare mirrors submit but records a job with state
# "prepared" and never contacts the scheduler.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq

    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    _KNIT_TEST_TMPDIR="$(mktemp -d)"

    # Pin the experiment root so a --setup name resolves deterministically under
    # <experiment-root>/setups (the __setup_path__ fallback), and jobs land in
    # <experiment-root>/jobs.
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    _KNIT_TEST_SETUP_ROOT="${_KNIT_TEST_TMPDIR}/setups"

    # Force the local backend regardless of the host scheduler: detection's
    # "<unknown>" degrades to local, so no scheduler is contacted.
    _KNIT_DETECTED_JOB_MANAGER="<unknown>"

    KNIT_SCRIPT_PATH="/fake/exp.sh"

    _knit_create_metadata_table
    # The jobs table is normally created lazily by submit's first invocation;
    # prepare records into it but does not own it, so create it up front here.
    _knit_db_setup_table "submit" "jobs"

    # Fail loudly if a test ever reaches the local launcher: prepare must not
    # dispatch.
    _knit_submit_local() { printf 'DISPATCHED\n' >&2; return 1; }
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    _KNIT_DETECTED_JOB_MANAGER=""
    knit_test_db_teardown
}

# Register a job "myjob" requiring an "mcenv" setup, and build that setup
# instance (with the provenance id marker so a used_by edge is recorded).
_register_myjob_with_setup() {
    local setup="${_KNIT_TEST_SETUP_ROOT}/setup"
    mkdir -p "${setup}"
    printf 'mcenv\n'        > "${setup}/.setup.type"
    printf 'setup-uuid-1\n' > "${setup}/.setup.id"

    _submit_myjob_fn() { :; }
    knit_register_job "myjob" _submit_myjob_fn "test job"
    knit_with_setup "mcenv"
    knit_done
}

# ---------- prepare : build without dispatch ----------

@test "prepare records a prepared job and does not dispatch" {
    _register_myjob_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare \
        --setup setup --nodes 2 --group sweep -- myjob)"

    knit_type_check "uuid" "${uuid}"

    # The job lands in the unified job root.
    local jobdir
    jobdir="$(find "${_KNIT_TEST_TMPDIR}/jobs" -mindepth 1 -maxdepth 1 -type d)"
    [ -n "${jobdir}" ]
    [ "${uuid}" = "$(basename "${jobdir}")" ]

    # The build wrote the script and froze the submission spec, but issued no
    # scheduler command: there is no .job.id.
    [ -f "${jobdir}/.job.sh" ]
    [ -f "${jobdir}/.submit" ]
    [ ! -f "${jobdir}/.job.id" ]
    grep -Fxq "backend=local" "${jobdir}/.submit"
    grep -Fxq "opt:nodes=2"   "${jobdir}/.submit"

    # The row is recorded with state "prepared" and native-cmd/hostnames empty
    # (filled only on release / at run time).
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT state FROM jobs WHERE id='${uuid}';")" = "prepared" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT job FROM jobs WHERE id='${uuid}';")" = "myjob" ]
    [ -z "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT native_cmd FROM jobs WHERE id='${uuid}';")" ]
    [ -z "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT hostnames FROM jobs WHERE id='${uuid}';")" ]
}

@test "prepare records the --group and submission columns" {
    _register_myjob_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare \
        --setup setup --nodes 3 --group julia-sweep -- myjob)"

    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT \"group\" FROM jobs WHERE id='${uuid}';")" = "julia-sweep" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT nodes FROM jobs WHERE id='${uuid}';")" = "3" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT setup FROM jobs WHERE id='${uuid}';")" = "setup" ]
}

@test "prepare records a used_by edge labelled for the submit table owner" {
    _register_myjob_with_setup

    local uuid
    uuid="$(_knit_invoke_command prepare --setup setup -- myjob)"

    # The edge target is the "submit" command (which owns the jobs table), not
    # "prepare"; the source is the setup instance.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT target_name FROM __provenance__ \
         WHERE target_id='${uuid}' AND edge_type='used_by';")" = "submit" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT source_id FROM __provenance__ \
         WHERE target_id='${uuid}' AND edge_type='used_by';")" = "setup-uuid-1" ]
}

@test "prepare twice in one process records two distinct prepared rows" {
    _register_myjob_with_setup

    local uuid1 uuid2
    uuid1="$(_knit_invoke_command prepare --setup setup -- myjob)"
    uuid2="$(_knit_invoke_command prepare --setup setup -- myjob)"

    [ "${uuid1}" != "${uuid2}" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE state='prepared';")" = "2" ]
}

# ---------- submit : --group ----------

@test "submit records the --group column" {
    _register_myjob_with_setup
    _knit_submit_local() { printf '9999\n'; }

    local uuid
    uuid="$(_knit_invoke_command submit \
        --setup setup --group release-a -- myjob)"

    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT \"group\" FROM jobs WHERE id='${uuid}';")" = "release-a" ]
    # A direct submit still dispatches: the launcher id is recorded.
    local jobdir
    jobdir="$(_knit_job_dir "${uuid}")"
    [ "$(cat "${jobdir}/.job.id")" = "9999" ]
}

# ---------- knit_register_job : reserved names ----------

@test "knit_register_job rejects the reserved name prepared" {
    _reserved_fn() { :; }
    run knit_register_job "prepared" _reserved_fn "d"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved"* ]]
}

@test "knit_register_job rejects the reserved name next" {
    _reserved_fn() { :; }
    run knit_register_job "next" _reserved_fn "d"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved"* ]]
}

@test "knit_register_job rejects the reserved name from" {
    _reserved_fn() { :; }
    run knit_register_job "from" _reserved_fn "d"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved"* ]]
}

# ---------- submit prepared / submit next : release ----------

# Make the local backend "dispatch" succeed by returning a fake launcher pid, so
# a release advances the row and writes .job.id without a real scheduler.
_stub_dispatch_ok() {
    _knit_submit_local() { printf '4242\n'; }
}

@test "submit prepared --id releases a prepared job" {
    _register_myjob_with_setup
    _stub_dispatch_ok

    local uuid released
    uuid="$(_knit_invoke_command prepare --setup setup -- myjob)"
    released="$(_knit_invoke_command submit prepared --id "${uuid}")"

    # The release echoes the job UUID and advances the row to "submitted".
    [ "${released}" = "${uuid}" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT state FROM jobs WHERE id='${uuid}';")" = "submitted" ]
    # The launcher id from the successful dispatch is recorded.
    local jobdir
    jobdir="$(_knit_job_dir "${uuid}")"
    [ "$(cat "${jobdir}/.job.id")" = "4242" ]
    # native-cmd is filled at release (empty while prepared).
    [ -n "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT native_cmd FROM jobs WHERE id='${uuid}';")" ]
}

@test "submit prepared --id on a non-prepared row is fatal" {
    _register_myjob_with_setup
    _stub_dispatch_ok

    local uuid
    uuid="$(_knit_invoke_command prepare --setup setup -- myjob)"
    _knit_invoke_command submit prepared --id "${uuid}"

    # A second release finds the row already "submitted": fatal, no re-dispatch.
    run _knit_invoke_command submit prepared --id "${uuid}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not prepared"* ]]
}

@test "submit prepared --id with an unknown id is fatal" {
    _register_myjob_with_setup

    run _knit_invoke_command submit prepared --id "does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No job found"* ]]
}

@test "submit prepared without --id is fatal" {
    _register_myjob_with_setup

    run _knit_invoke_command submit prepared
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires --id"* ]]
}

@test "submit next releases prepared jobs in prepare order" {
    _register_myjob_with_setup
    _stub_dispatch_ok

    local u1 u2 u3
    u1="$(_knit_invoke_command prepare --setup setup -- myjob)"
    u2="$(_knit_invoke_command prepare --setup setup -- myjob)"
    u3="$(_knit_invoke_command prepare --setup setup -- myjob)"

    # uuidv7 ids are time-ordered, so oldest-prepared releases first.
    [ "$(_knit_invoke_command submit next)" = "${u1}" ]
    [ "$(_knit_invoke_command submit next)" = "${u2}" ]
    [ "$(_knit_invoke_command submit next)" = "${u3}" ]
}

@test "submit next returns non-zero when no prepared job remains" {
    _register_myjob_with_setup
    _stub_dispatch_ok

    local uuid
    uuid="$(_knit_invoke_command prepare --setup setup -- myjob)"
    _knit_invoke_command submit next >/dev/null

    run _knit_invoke_command submit next
    [ "$status" -ne 0 ]
}

@test "submit next --type filters by job type" {
    _register_myjob_with_setup
    _stub_dispatch_ok
    _submit_other_fn() { :; }
    knit_register_job "other" _submit_other_fn "another test job"
    knit_with_setup "mcenv"
    knit_done

    local u_my u_other
    u_my="$(_knit_invoke_command prepare --setup setup -- myjob)"
    u_other="$(_knit_invoke_command prepare --setup setup -- other)"

    # Selecting --type other skips the older myjob and releases the other job.
    [ "$(_knit_invoke_command submit next --type other)" = "${u_other}" ]
    # myjob is still prepared afterwards.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT state FROM jobs WHERE id='${u_my}';")" = "prepared" ]
}

@test "submit next --group filters by group" {
    _register_myjob_with_setup
    _stub_dispatch_ok

    local u_a u_b
    u_a="$(_knit_invoke_command prepare --setup setup --group a -- myjob)"
    u_b="$(_knit_invoke_command prepare --setup setup --group b -- myjob)"

    [ "$(_knit_invoke_command submit next --group b)" = "${u_b}" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT state FROM jobs WHERE id='${u_a}';")" = "prepared" ]
}

@test "submit next claims exactly one prepared row" {
    _register_myjob_with_setup
    _stub_dispatch_ok

    _knit_invoke_command prepare --setup setup -- myjob >/dev/null
    _knit_invoke_command prepare --setup setup -- myjob >/dev/null

    _knit_invoke_command submit next >/dev/null

    # One row released (submitted), one still prepared: the claim moved a single
    # row, not both.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE state='submitted';")" = "1" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM jobs WHERE state='prepared';")" = "1" ]
}

@test "submit prepared --wait threads the wait flag to the backend" {
    _register_myjob_with_setup
    _stub_dispatch_ok
    # Record that the backend was asked to block.
    _knit_wait_local() { printf 'waited\n' > "${_KNIT_TEST_TMPDIR}/.waited"; }

    local uuid
    uuid="$(_knit_invoke_command prepare --setup setup -- myjob)"
    _knit_invoke_command submit prepared --id "${uuid}" --wait >/dev/null

    # A prepared job freezes wait=false; the release --wait must override it so the
    # local backend blocks (calls _knit_wait_local).
    [ -f "${_KNIT_TEST_TMPDIR}/.waited" ]
}

@test "submit next without --wait does not block" {
    _register_myjob_with_setup
    _stub_dispatch_ok
    _knit_wait_local() { printf 'waited\n' > "${_KNIT_TEST_TMPDIR}/.waited"; }

    _knit_invoke_command prepare --setup setup -- myjob >/dev/null
    _knit_invoke_command submit next >/dev/null

    [ ! -f "${_KNIT_TEST_TMPDIR}/.waited" ]
}
