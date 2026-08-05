#!/usr/bin/env bash
# Integration test 07_job_cancel.
#
# Exercises the `job cancel` command (J9) against the cluster scheduler:
#   - submit a long-running job (no --wait) so it starts on a compute node
#   - wait until the jobs row reaches "running" (compute-side before-cb)
#   - cancel the job with `knit job cancel --id <uuid>`, which terminates it
#     through the scheduler (scancel/qdel) and marks the row "killed"
#   - verify the job is no longer running and its row is "killed"
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/07_job_cancel/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/07-job-cancel-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/07_job_cancel/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap + setup
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-07"
SQLITE="${WORKDIR}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQLITE}"

./experiment.sh setup --name env -- env
check_file "setups/env/.activate.sh" "setup produced .activate.sh"

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
# Cancel the running job through knit. `job cancel` terminates it via the
# scheduler and records the jobs row as "killed".
# --------------------------------------------------------------------------
./experiment.sh job cancel --id "${uuid}"

# The row must be "killed" (set by `job cancel` and/or the compute-side trap).
killed=0
for _ in $(seq 1 90); do
    [[ "$(state_of)" == "killed" ]] && { killed=1; break; }
    sleep 1
done
check_eq "${killed}" "1" "cancelled job was recorded as killed"

# The scheduler must no longer be running the launcher.
gone=0
for _ in $(seq 1 90); do
    if command -v squeue >/dev/null 2>&1; then
        squeue -h -j "${launcher}" -o '%T' 2>/dev/null | grep -q . || { gone=1; break; }
    elif command -v qstat >/dev/null 2>&1; then
        st="$(qstat -x -f "${launcher}" 2>/dev/null \
            | awk -F'=' '/job_state/ { gsub(/ /, "", $2); print $2; exit }')"
        [[ -z "${st}" || "${st}" == "E" || "${st}" == "F" ]] && { gone=1; break; }
    else
        gone=1; break
    fi
    sleep 1
done
check_eq "${gone}" "1" "scheduler no longer runs the cancelled job"

assert_summary
