#!/usr/bin/env bash
# Integration test 05_job_killed.
#
# Exercises M8 kill detection against the cluster scheduler:
#   - submit a long-running job (no --wait) so it starts on a compute node
#   - wait until the jobs row reaches "running" (compute-side before-cb)
#   - cancel the job through the scheduler (scancel/qdel)
#   - the scheduler signals the job before killing it; knit's compute-side trap
#     records the jobs row as "killed" before the process dies
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/05_job_killed/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/05-job-killed-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/05_job_killed/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap + setup
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-05"
SQLITE="${WORKDIR}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQLITE}"

./experiment.sh setup --name env -- env
check_file "setups/env/.activate.sh" "setup produced .activate.sh"

# --------------------------------------------------------------------------
# Detect the scheduler and its cancel command.
# --------------------------------------------------------------------------
if command -v sbatch >/dev/null 2>&1; then
    CANCEL=(scancel)
elif command -v qsub >/dev/null 2>&1; then
    CANCEL=(qdel)
elif command -v flux >/dev/null 2>&1; then
    CANCEL=(flux cancel)
else
    fail "no supported scheduler (sbatch/qsub/flux) found on the login node"
fi

# --------------------------------------------------------------------------
# Submit the sleeper WITHOUT --wait so it runs asynchronously.
# --------------------------------------------------------------------------
uuid=$(./experiment.sh submit --setup env -- sleeper)
jobdir="${WORKDIR}/jobs/${uuid}"
check_file "${jobdir}/.job.id" "launcher job id recorded"
launcher=$(cat "${jobdir}/.job.id")

state_of() {
    "${SQLITE}" ".knit/knit.db" \
        "SELECT state FROM jobs WHERE id='${uuid}';"
}

# --------------------------------------------------------------------------
# Wait until the compute-side before-callback marks the job "running".
# --------------------------------------------------------------------------
running=0
for _ in $(seq 1 90); do
    [[ "$(state_of)" == "running" ]] && { running=1; break; }
    sleep 1
done
check_eq "${running}" "1" "job reached the running state on a compute node"

# --------------------------------------------------------------------------
# Cancel the running job. The scheduler signals it; knit's trap records it as
# "killed" before the process is torn down.
# --------------------------------------------------------------------------
"${CANCEL[@]}" "${launcher}"

killed=0
for _ in $(seq 1 90); do
    [[ "$(state_of)" == "killed" ]] && { killed=1; break; }
    sleep 1
done
check_eq "${killed}" "1" "cancelled job was recorded as killed"

assert_summary
