#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    _KNIT_TEST_TMPDIR="$(mktemp -d)"

    # Minimal jobs table: only the columns reconcile touches.
    sqlite3 "${_KNIT_DATABASE}" \
        "CREATE TABLE jobs (id TEXT, job TEXT, \"group\" TEXT, state TEXT);"

    # Stub _knit_job_dir to resolve inside the test tree.
    _knit_job_dir() { printf '%s/jobs/%s\n' "${_KNIT_TEST_TMPDIR}" "$1"; }

    # Stub _knit_sched_backend so it does not touch metadata.
    _knit_sched_backend() { local -n __b=$1; __b="local"; }
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

# ---------- helpers ----------

_seed_job() {
    local id="$1" state="$2" job="${3:-myjob}" group="${4:-}"
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO jobs VALUES ('${id}','${job}','${group}','${state}');"
}

_job_state() {
    sqlite3 "${_KNIT_DATABASE}" "SELECT state FROM jobs WHERE id='$1';"
}

_make_jobdir() {
    local id="$1" launcher_id="${2:-}"
    local d="${_KNIT_TEST_TMPDIR}/jobs/${id}"
    mkdir -p "${d}"
    if [[ -n "${launcher_id}" ]]; then
        printf '%s\n' "${launcher_id}" > "${d}/.job.id"
    fi
}

# ---------- _knit_job_reconcile_set_state (guarded write) ----------

@test "reconcile_set_state updates a running row to the new state" {
    _seed_job "r1" "running"
    _knit_job_reconcile_set_state "r1" "killed"
    [ "$(_job_state "r1")" = "killed" ]
}

@test "reconcile_set_state does not clobber a row already in terminal state" {
    _seed_job "r1" "killed"
    _knit_job_reconcile_set_state "r1" "completed"
    [ "$(_job_state "r1")" = "killed" ]
}

@test "reconcile_set_state updates a submitting row to the new state" {
    _seed_job "r1" "submitting"
    _knit_job_reconcile_set_state "r1" "killed"
    [ "$(_job_state "r1")" = "killed" ]
}

# ---------- _knit_job_reconcile_apply: verdict mapping ----------

@test "reconcile_apply moves a running row to killed when scheduler says killed" {
    _seed_job "r1" "running"
    _make_jobdir "r1" "42"
    _knit_sched_status() { local -n __r=$1; __r="killed"; }
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "r1")" = "killed" ]
}

@test "reconcile_apply leaves a running row unchanged when scheduler says running" {
    _seed_job "r1" "running"
    _make_jobdir "r1" "42"
    _knit_sched_status() { local -n __r=$1; __r="running"; }
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "r1")" = "running" ]
}

@test "reconcile_apply moves a running row to completed when scheduler says completed" {
    _seed_job "r1" "running"
    _make_jobdir "r1" "42"
    _knit_sched_status() { local -n __r=$1; __r="completed"; }
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "r1")" = "completed" ]
}

@test "reconcile_apply moves a running row to failed when scheduler says failed" {
    _seed_job "r1" "running"
    _make_jobdir "r1" "42"
    _knit_sched_status() { local -n __r=$1; __r="failed"; }
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "r1")" = "failed" ]
}

@test "reconcile_apply maps an unknown verdict to killed" {
    _seed_job "r1" "running"
    _make_jobdir "r1" "42"
    _knit_sched_status() { local -n __r=$1; __r="unknown"; }
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "r1")" = "killed" ]
}

# ---------- .job.id-less rule ----------

@test "reconcile_apply skips submitting row with no launcher id when no --id given" {
    _seed_job "s1" "submitting"
    _make_jobdir "s1"
    _knit_sched_status() { local -n __r=$1; __r="killed"; }
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "s1")" = "submitting" ]
}

@test "reconcile_apply treats submitting row with no launcher id as killed when --id given" {
    _seed_job "s1" "submitting"
    _make_jobdir "s1"
    _knit_sched_status() { local -n __r=$1; __r="killed"; }
    _knit_job_reconcile_apply "false" "s1" "" ""
    [ "$(_job_state "s1")" = "killed" ]
}

@test "reconcile_apply treats running row with no launcher id as killed (no --id)" {
    _seed_job "r1" "running"
    _make_jobdir "r1"
    _knit_sched_status() { local -n __r=$1; __r="killed"; }
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "r1")" = "killed" ]
}

# ---------- selectors ----------

@test "reconcile_apply --id selects only the named job" {
    _seed_job "r1" "running"
    _seed_job "r2" "running"
    _make_jobdir "r1" "1"
    _make_jobdir "r2" "2"
    _knit_sched_status() { local -n __r=$1; __r="killed"; }
    _knit_job_reconcile_apply "false" "r1" "" ""
    [ "$(_job_state "r1")" = "killed" ]
    [ "$(_job_state "r2")" = "running" ]
}

@test "reconcile_apply --group selects only jobs in that group" {
    _seed_job "r1" "running" "myjob" "grpA"
    _seed_job "r2" "running" "myjob" "grpB"
    _make_jobdir "r1" "1"
    _make_jobdir "r2" "2"
    _knit_sched_status() { local -n __r=$1; __r="killed"; }
    _knit_job_reconcile_apply "false" "" "grpA" ""
    [ "$(_job_state "r1")" = "killed" ]
    [ "$(_job_state "r2")" = "running" ]
}

@test "reconcile_apply --type selects only jobs of that type" {
    _seed_job "r1" "running" "alpha"
    _seed_job "r2" "running" "beta"
    _make_jobdir "r1" "1"
    _make_jobdir "r2" "2"
    _knit_sched_status() { local -n __r=$1; __r="killed"; }
    _knit_job_reconcile_apply "false" "" "" "alpha"
    [ "$(_job_state "r1")" = "killed" ]
    [ "$(_job_state "r2")" = "running" ]
}

# ---------- non-active rows never matched ----------

@test "reconcile_apply ignores prepared and completed rows" {
    _seed_job "p1" "prepared"
    _seed_job "c1" "completed"
    _make_jobdir "p1" "1"
    _make_jobdir "c1" "2"
    _knit_sched_status() { local -n __r=$1; __r="killed"; }
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "p1")" = "prepared" ]
    [ "$(_job_state "c1")" = "completed" ]
}

# ---------- --dry-run ----------

@test "reconcile_apply with dry-run reports would-be change but writes nothing" {
    _seed_job "r1" "running"
    _make_jobdir "r1" "42"
    _knit_sched_status() { local -n __r=$1; __r="killed"; }
    run _knit_job_reconcile_apply "true" "" "" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"r1 killed"* ]]
    [ "$(_job_state "r1")" = "running" ]
}

@test "reconcile_apply with dry-run does not change a submitting row either" {
    _seed_job "s1" "submitting"
    _make_jobdir "s1" "99"
    _knit_sched_status() { local -n __r=$1; __r="killed"; }
    run _knit_job_reconcile_apply "true" "" "" ""
    [ "$status" -eq 0 ]
    [ "$(_job_state "s1")" = "submitting" ]
}

# ---------- backend tag routing (.job.id tag drives the status query) ----------

@test "reconcile routes a tagged id to its own backend's status query" {
    _seed_job "r1" "running"
    local d="${_KNIT_TEST_TMPDIR}/jobs/r1"
    mkdir -p "${d}"
    printf 'local:4242\n' > "${d}/.job.id"
    # Real _knit_sched_status dispatch; stub only the local backend's status and
    # capture the id it receives (the tag must be stripped before the query).
    _knit_sched_local_status() {
        local -n __r=$1; shift
        printf '%s\n' "$1" > "${_KNIT_TEST_TMPDIR}/probed"
        __r="killed"
    }
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "r1")" = "killed" ]
    [ "$(cat "${_KNIT_TEST_TMPDIR}/probed")" = "4242" ]
}

# ---------- pilot sub-job cascade (reconcile via the parent pilot) ----------

# Write a tagged .job.id holding $2 for the job directory of id $1.
_tag_jobid() {
    local d="${_KNIT_TEST_TMPDIR}/jobs/$1"
    mkdir -p "${d}"
    printf '%s\n' "$2" > "${d}/.job.id"
}

@test "reconcile marks a pilot sub-job killed when its parent pilot is gone" {
    _seed_job "sub1" "running"
    _tag_jobid "sub1" "pilot:par1:sub1"
    _tag_jobid "par1" "pbs:999.server"
    # Real dispatch + real pilot walk; stub only the parent's pbs status.
    _knit_sched_pbs_status() { local -n __r=$1; __r="killed"; }
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "sub1")" = "killed" ]
}

@test "reconcile leaves a pilot sub-job running when its parent pilot still runs" {
    _seed_job "sub1" "running"
    _tag_jobid "sub1" "pilot:par1:sub1"
    _tag_jobid "par1" "pbs:999.server"
    _knit_sched_pbs_status() { local -n __r=$1; __r="running"; }
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "sub1")" = "running" ]
}

@test "reconcile marks a pilot sub-job killed when the parent .job.id is missing" {
    _seed_job "sub1" "running"
    _tag_jobid "sub1" "pilot:par1:sub1"
    # No par1 directory / .job.id at all.
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "sub1")" = "killed" ]
}

@test "reconcile resolves a nested pilot sub-job through both hops" {
    _seed_job "sub1" "running"
    _tag_jobid "sub1" "pilot:par1:sub1"   # parent par1 is itself a pilot ...
    _tag_jobid "par1" "pilot:gp1:par1"    # ... whose parent gp1 is a pbs job
    _tag_jobid "gp1"  "pbs:999.server"
    _knit_sched_pbs_status() { local -n __r=$1; __r="killed"; }
    _knit_job_reconcile_apply "false" "" "" ""
    [ "$(_job_state "sub1")" = "killed" ]
}
