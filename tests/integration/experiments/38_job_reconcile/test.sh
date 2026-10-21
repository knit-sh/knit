#!/usr/bin/env bash
# Integration test 38_job_reconcile.
#
# Exercises `knit job reconcile` and `submit drain --reconcile` against the real
# cluster scheduler:
#   - A completed job's state is forced back to "running" (simulating a hard
#     SIGKILL that bypassed the kill trap). Its .job.id is still present, so
#     reconcile can query the scheduler, which reports the job gone.
#   - `job reconcile` moves the stuck row to a terminal state.
#   - A genuinely still-running control job is left untouched.
#   - `submit drain --reconcile --retry killed` turns a stuck-running job into
#     completed in a single pass.
#   - Pilot sub-jobs: when a pilot and its sub-jobs are forced stuck at "running"
#     (a hard-killed pilot), reconcile walks each sub-job to its parent pilot and
#     marks the orphans killed; a sub-job under a still-running pilot is left
#     running (no false kill).
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/38_job_reconcile/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/38-job-reconcile-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/38_job_reconcile/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-38"
SQLITE="${WORKDIR}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQLITE}"
DB="${WORKDIR}/.knit/knit.db"

# @fn state_of()
# The recorded lifecycle state of one job id.
state_of() {
    "${SQLITE}" "${DB}" "SELECT state FROM jobs WHERE id='$1';"
}

# @fn set_state()
# Force a job's lifecycle state directly in the database, simulating what a
# hard SIGKILL leaves behind when the kill trap cannot run.
set_state() {
    "${SQLITE}" "${DB}" "UPDATE jobs SET state='$2' WHERE id='$1';"
}

# @fn subjob_uuids_for_pilot()
# The UUIDs of a pilot's sub-jobs, via the two-hop provenance walk (resolves once
# the pilot body has completed): the pilot submission -> its body's "campaign"
# call edge, then that body's "campaign -> submit" call edges, whose targets are
# the sub-jobs' jobs.id. Mirrors 36_pilot_job.
subjob_uuids_for_pilot() {
    local pilot_uuid="$1" body_id
    body_id=$("${SQLITE}" "${DB}" \
        "SELECT target_id FROM __provenance__
         WHERE source_id='${pilot_uuid}' AND target_name='submit:campaign'
           AND edge_type='call';")
    [[ -n "${body_id}" ]] || return 0
    "${SQLITE}" "${DB}" \
        "SELECT target_id FROM __provenance__
         WHERE source_id='${body_id}' AND source_name='submit:campaign'
           AND target_name='submit' AND edge_type='call';"
}

# @fn wait_killed()
# Poll (bounded) until a job reaches a terminal state; tolerate completed as an
# acceptable alternative to killed for a sub-job that raced to the end.
wait_killed() {
    local id="$1" _ st
    for _ in $(seq 1 60); do
        st=$(state_of "${id}")
        [[ "${st}" == "killed" || "${st}" == "completed" ]] && return 0
        sleep 2
    done
    return 1
}

# ==========================================================================
# 1. job reconcile moves a stuck running row to a terminal state.
# ==========================================================================
r1=$(./experiment.sh prepare --group reconcile -- sim --n 1)
r2=$(./experiment.sh prepare --group reconcile -- sim --n 2)
check_eq "$(state_of "${r1}")" "prepared" "r1 starts prepared"
check_eq "$(state_of "${r2}")" "prepared" "r2 starts prepared"

# Drain both jobs to completion (--max-inflight 1 releases and waits one at a time).
./experiment.sh submit drain --group reconcile
check_eq "$(state_of "${r1}")" "completed" "r1 completed after drain"
check_eq "$(state_of "${r2}")" "completed" "r2 completed after drain"

# Simulate a hard kill on r1: force its state back to running.
set_state "${r1}" "running"
check_eq "$(state_of "${r1}")" "running" "r1 state forced to running (simulated stuck job)"

# Reconcile: the scheduler reports r1's job-id as gone (finished), so it maps
# to a terminal state. r2, which is completed and not in the active set, is
# untouched.
./experiment.sh job reconcile --group reconcile
# The scheduler may report it as completed or killed depending on backend and
# how long since the job finished; either is acceptable. The key assertion is
# that it is no longer stuck at running.
r1_state="$(state_of "${r1}")"
[[ "${r1_state}" != "running" ]] \
    && __assert_pass "job reconcile moved r1 out of running (got: ${r1_state})" \
    || { printf 'FAIL: r1 is still running after reconcile\n' >&2; exit 1; }
check_eq "$(state_of "${r2}")" "completed" "r2 was not touched by reconcile (already completed)"

# ==========================================================================
# 2. submit drain --reconcile --retry killed recovers a stuck job in one pass.
# ==========================================================================
# Prepare a fresh job in a new group.
s1=$(./experiment.sh prepare --group recover -- sim --n 3)
./experiment.sh submit drain --group recover
check_eq "$(state_of "${s1}")" "completed" "s1 completed on the first drain"

# Simulate a hard kill.
set_state "${s1}" "running"
check_eq "$(state_of "${s1}")" "running" "s1 state forced to running (simulated stuck)"

# A single drain pass with --reconcile --retry killed:
#   reconcile:  running -> killed (scheduler reports job gone)
#   retry:      killed  -> prepared
#   drain:      prepared -> completed
./experiment.sh submit drain --group recover --reconcile --retry killed
check_eq "$(state_of "${s1}")" "completed" \
    "submit drain --reconcile --retry turned stuck-running into completed"

# ==========================================================================
# 3. Pilot sub-jobs of a hard-killed pilot are reconciled via the parent pilot.
# ==========================================================================
check_exec "${WORKDIR}/.knit/knit-pilotd/bin/knit-pilotd" \
    "bootstrap provisioned the knit-pilotd daemon"

# Run a pilot to completion: its sub-jobs record "pilot:<parent>:<sub-job>" in
# their .job.id (the parent linkage reconcile walks), the pilot records a real
# scheduler id in its own .job.id.
p_uuid=$(./experiment.sh submit --nodes 2 --wait -- campaign --count 2 --sleep 2)
check_eq "$(state_of "${p_uuid}")" "completed" "the pilot completed"

mapfile -t subs < <(subjob_uuids_for_pilot "${p_uuid}")
check_eq "${#subs[@]}" "2" "the pilot submitted 2 worker sub-jobs"
for w in "${subs[@]}"; do
    check_eq "$(state_of "${w}")" "completed" "sub-job ${w:0:8} completed"
done

# Simulate a hard SIGKILL of the whole pilot allocation: the pilot and every
# sub-job are left stuck at "running" (no kill trap ran).
set_state "${p_uuid}" "running"
for w in "${subs[@]}"; do set_state "${w}" "running"; done

# Reconcile. The pilot row is resolved directly against the real scheduler (its
# job finished); each sub-job is resolved by walking to the parent pilot, now
# gone, so the orphan is marked killed.
./experiment.sh job reconcile

p_state=$(state_of "${p_uuid}")
[[ "${p_state}" != "running" && "${p_state}" != "submitting" ]] \
    && __assert_pass "the pilot row was moved out of running (got: ${p_state})" \
    || { printf 'FAIL: the pilot row is still %s after reconcile\n' "${p_state}" >&2; exit 1; }
for w in "${subs[@]}"; do
    check_eq "$(state_of "${w}")" "killed" \
        "orphaned sub-job ${w:0:8} reconciled to killed via the gone parent pilot"
done

# ==========================================================================
# 4. A sub-job under a still-running pilot is left running (no false kill).
# ==========================================================================
# A long-sleeping pilot, submitted without --wait so it keeps running while we
# reconcile from the login node.
live_uuid=$(./experiment.sh submit --nodes 2 -- campaign --count 2 --sleep 120)

# The pilot writes each sub-job UUID to .pilot.subjobs as it submits them (eager,
# before its body blocks in `knit job wait`), so read that while it runs.
subjobs_file="${WORKDIR}/jobs/${live_uuid}/.pilot.subjobs"
live_subs=()
for _ in $(seq 1 60); do
    if [[ -r "${subjobs_file}" ]]; then
        mapfile -t live_subs < "${subjobs_file}"
        [[ "${#live_subs[@]}" -eq 2 ]] && break
    fi
    sleep 2
done
check_eq "${#live_subs[@]}" "2" "the live pilot submitted 2 worker sub-jobs"

# Wait until at least one sub-job is actually running under the daemon.
running_sub=""
for _ in $(seq 1 30); do
    for w in "${live_subs[@]}"; do
        [[ "$(state_of "${w}")" == "running" ]] && { running_sub="${w}"; break; }
    done
    [[ -n "${running_sub}" ]] && break
    sleep 2
done
[[ -n "${running_sub}" ]] || fail "no live sub-job reached running"

# Reconcile while the pilot is alive: the parent reports running, so the sub-job
# must be left untouched — reconcile must not false-kill a live sub-job.
./experiment.sh job reconcile
check_eq "$(state_of "${running_sub}")" "running" \
    "a live sub-job under a still-running pilot is left running by reconcile"

# Clean up: cancel the live pilot and let its sub-tree reach a terminal state.
./experiment.sh job cancel --id "${live_uuid}"
wait_killed "${live_uuid}" || fail "cancelled live pilot did not reach a terminal state"

assert_summary
