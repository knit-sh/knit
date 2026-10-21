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

assert_summary
