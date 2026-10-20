#!/usr/bin/env bash
# Integration test 37_drain_retry.
#
# Exercises the retry path of the durable prepare/drain queue against the real
# cluster scheduler:
#   - `job reset` moves a terminal-failed job back to "prepared", bumping its
#     retries count, so a later drain re-runs it;
#   - `submit drain --retry killed` re-queues a job left "killed" by a simulated
#     mid-drain kill and runs it to completion, leaving the other jobs untouched;
#   - `--max-retries` refuses to re-queue a job already at its retry cap.
#
# A mid-drain kill is simulated by writing a drained job's state back to "killed"
# directly in the database (what a pilot killed at walltime leaves behind).
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/37_drain_retry/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/37-drain-retry-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/37_drain_retry/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-37"
SQLITE="${WORKDIR}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQLITE}"
DB="${WORKDIR}/.knit/knit.db"

# @fn state_of()
# The recorded lifecycle state of one job id (empty when the row is gone).
state_of() {
    "${SQLITE}" "${DB}" "SELECT state FROM jobs WHERE id='$1';"
}

# @fn retries_of()
# The recorded retries count of one job id.
retries_of() {
    "${SQLITE}" "${DB}" "SELECT retries FROM jobs WHERE id='$1';"
}

# @fn set_state()
# Force a job's lifecycle state directly in the database, simulating what a
# scheduler kill (or a dead drainer) would record for an in-flight job.
set_state() {
    "${SQLITE}" "${DB}" "UPDATE jobs SET state='$2' WHERE id='$1';"
}

# @fn prepared_count()
# Number of jobs in state "prepared" within one group.
prepared_count() {
    "${SQLITE}" "${DB}" \
        "SELECT count(*) FROM jobs WHERE \"group\"='$1' AND state='prepared';"
}

# ==========================================================================
# 1. submit drain --retry re-queues a killed job and runs it to completion.
# ==========================================================================
p1=$(./experiment.sh prepare --group retry -- sim --n 1)
p2=$(./experiment.sh prepare --group retry -- sim --n 2)
p3=$(./experiment.sh prepare --group retry -- sim --n 3)
check_eq "$(prepared_count retry)" "3" "three jobs prepared in the retry group"

# First pass: drain the whole group to completion.
./experiment.sh submit drain --group retry --max-inflight 2
check_eq "$(state_of "${p2}")" "completed" "the middle job completed on the first pass"

# Simulate a pilot killed while p2 was in flight: its row is left "killed".
set_state "${p2}" "killed"
check_eq "$(state_of "${p2}")" "killed" "the in-flight job is left killed"

# Resume: --retry re-queues the killed job and drains it again.
./experiment.sh submit drain --group retry --retry killed
check_eq "$(state_of "${p2}")" "completed" "the killed job completed on the retry"
check_eq "$(retries_of "${p2}")" "1" "the retry was counted in the retries column"
check_eq "$(state_of "${p1}")" "completed" "an untouched job stayed completed"
check_eq "$(retries_of "${p1}")" "0" "an untouched job was not retried"
check_eq "$(state_of "${p3}")" "completed" "the other untouched job stayed completed"
check_eq "$(prepared_count retry)" "0" "nothing is left prepared after the retry"

# ==========================================================================
# 2. Standalone job reset re-queues a failed job for a later drain.
# ==========================================================================
r1=$(./experiment.sh prepare --group manual -- sim --n 1)
./experiment.sh submit drain --group manual >/dev/null 2>&1
check_eq "$(state_of "${r1}")" "completed" "the manual job completed"

# Simulate it failing, then reset it by id.
set_state "${r1}" "failed"
./experiment.sh job reset --id "${r1}"
check_eq "$(state_of "${r1}")" "prepared" "job reset re-queued the failed job"
check_eq "$(retries_of "${r1}")" "1" "job reset counted the attempt"

# It drains to completion from the prepared state again.
./experiment.sh submit drain --group manual
check_eq "$(state_of "${r1}")" "completed" "the re-queued job completed"

# ==========================================================================
# 3. --max-retries refuses to re-queue a job already at the cap.
# ==========================================================================
c1=$(./experiment.sh prepare --group cap -- sim --n 1)
./experiment.sh submit drain --group cap >/dev/null 2>&1
# Simulate a job killed three times already: killed with retries at the cap.
"${SQLITE}" "${DB}" "UPDATE jobs SET state='killed', retries=3 WHERE id='${c1}';"

# A retry capped at 3 must refuse this job (3 >= 3): it stays killed, not re-run.
set +e
./experiment.sh submit drain --group cap --retry killed --max-retries 3 \
    >/dev/null 2>&1
set -e
check_eq "$(state_of "${c1}")" "killed" "a job at the retry cap is left killed"
check_eq "$(retries_of "${c1}")" "3" "the capped job's retries count did not advance"
check_eq "$(prepared_count cap)" "0" "the capped job was not re-queued"

assert_summary
