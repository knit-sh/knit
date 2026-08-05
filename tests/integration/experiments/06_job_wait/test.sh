#!/usr/bin/env bash
# Integration test 06_job_wait.
#
# Exercises `job wait` blocking on the real scheduler:
#   - submit a short job (no --wait) so it runs asynchronously on a compute node
#   - call `job wait --id <uuid>`, which blocks on the scheduler's own view of
#     the job (squeue on Slurm, qstat on PBS) instead of busy-polling the DB
#   - when the job finishes, its compute-side after-callback has recorded the
#     row as "completed", so `job wait` prints "completed" and exits 0
#   - a `job wait` on an already-terminal job returns immediately
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/06_job_wait/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/06-job-wait-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/06_job_wait/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap + setup
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-06"
SQLITE="${WORKDIR}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQLITE}"

./experiment.sh setup --name env -- env
check_file "setups/env/.activate.sh" "setup produced .activate.sh"

# --------------------------------------------------------------------------
# Submit the worker WITHOUT --wait so it runs asynchronously.
# --------------------------------------------------------------------------
uuid=$(./experiment.sh submit --setup env -- worker)
jobdir="${WORKDIR}/jobs/${uuid}"
check_file "${jobdir}/.job.id" "launcher job id recorded"

state_of() {
    "${SQLITE}" ".knit/knit.db" \
        "SELECT state FROM jobs WHERE id='${uuid}';"
}

# The job is still running (it sleeps): it must not already be terminal.
initial="$(state_of)"
not_terminal="no"
[[ "${initial}" != "completed" && "${initial}" != "killed" ]] && not_terminal="yes"
check_eq "${not_terminal}" "yes" \
    "job is not terminal before waiting (state='${initial}')"

# --------------------------------------------------------------------------
# Block on the scheduler until the job finishes. This must actually wait (the
# job sleeps), then report the recorded terminal state.
# --------------------------------------------------------------------------
start=$(date +%s)
set +e
waited="$(./experiment.sh job wait --id "${uuid}")"
rc=$?
set -e
end=$(date +%s)

check_eq "${rc}" "0" "job wait exited 0 for a job that completes"
check_eq "${waited}" "completed" "job wait reported the completed state"
elapsed=$(( end - start ))
blocked="no"
[[ "${elapsed}" -ge 5 ]] && blocked="yes"
check_eq "${blocked}" "yes" "job wait blocked on the scheduler (waited ${elapsed}s)"
check_eq "$(state_of)" "completed" "job recorded as completed after the wait"

# --------------------------------------------------------------------------
# A second wait on the now-terminal job returns immediately with the same state.
# --------------------------------------------------------------------------
again="$(./experiment.sh job wait --id "${uuid}")"
check_eq "${again}" "completed" "job wait on an already-completed job returns it"

# --------------------------------------------------------------------------
# An unknown id is an error, not an endless wait.
# --------------------------------------------------------------------------
set +e
./experiment.sh job wait --id "no-such-job" >/dev/null 2>&1
rc=$?
set -e
unknown_failed="no"
[[ "${rc}" -ne 0 ]] && unknown_failed="yes"
check_eq "${unknown_failed}" "yes" "job wait on an unknown id fails"

assert_summary
