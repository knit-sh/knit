#!/usr/bin/env bash
# Integration test 29_queue_auto.
#
# Exercises automatic queue selection end to end against the cluster scheduler:
#   - a machine profile declares two queues: a decoy "solo" that accepts at most
#     one node, and the real cluster queue (Slurm "main" / PBS "workq") that
#     accepts up to two;
#   - bootstrap --default-queue auto overrides the profile's own default_queue,
#     so every submission selects a queue automatically;
#   - submit --nodes 2 (no --queue) therefore skips the one-node decoy and lands
#     on the real queue. Knit resolves "auto" to that concrete queue and writes it
#     into the batch script's directives; the job then runs there to completion.
#
# This proves first-fit selection (skip a too-small queue), that the concrete
# queue — never the literal "auto" — reaches the scheduler, and that the new
# bootstrap --default-queue flag stores "auto" verbatim.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/29_queue_auto/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/29-queue-auto-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/29_queue_auto/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Detect which scheduler this cluster runs so the profile's queue names and the
# expected directive match the backend knit will use.
# --------------------------------------------------------------------------
if command -v sbatch >/dev/null 2>&1; then
    BACKEND="slurm"
    SCHED_CMD="sbatch"
    REAL_QUEUE="main"
    NODE_PREFIX="slurm-compute"
    QUEUE_DIRECTIVE="#SBATCH --partition="
elif command -v qsub >/dev/null 2>&1; then
    BACKEND="pbs"
    SCHED_CMD="qsub"
    REAL_QUEUE="workq"
    NODE_PREFIX="pbs-compute"
    QUEUE_DIRECTIVE="#PBS -q "
else
    fail "no supported scheduler (sbatch/qsub) found on the login node"
fi

# --------------------------------------------------------------------------
# Write a machine profile with declared queues. "solo" (declared first) accepts a
# single node and is a decoy; the real cluster queue accepts up to two. The
# profile's own default_queue is the decoy on purpose — the bootstrap flag below
# overrides it with "auto".
# --------------------------------------------------------------------------
cat > "${WORKDIR}/profile.json" <<EOF
{
    "name": "test/queue-auto",
    "description": "Integration profile with declared queues for --queue auto.",
    "scheduler": {
        "type": "${BACKEND}",
        "command": "${SCHED_CMD}",
        "default_queue": "solo",
        "queues": {
            "solo":          { "min_nodes": 1, "max_nodes": 1 },
            "${REAL_QUEUE}": { "min_nodes": 1, "max_nodes": 2 }
        }
    }
}
EOF

# --------------------------------------------------------------------------
# Bootstrap with the profile and make auto the project-wide default queue. The
# --default-queue flag must win over the profile's default_queue ("solo").
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-29" \
    --profile ./profile.json --default-queue auto
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__default_queue__';" \
    "auto" \
    "bootstrap --default-queue auto stored 'auto' verbatim (over the profile default)"

# --------------------------------------------------------------------------
# Submit a two-node job with no --queue: default_queue=auto selects the queue.
# --wait blocks until completion; submit prints the job UUID.
# --------------------------------------------------------------------------
uuid=$(./experiment.sh submit --nodes 2 --wait -- hello)

jobdir=$(find "${WORKDIR}/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "${jobdir}" ]] || fail "no job directory created under jobs"
check_eq "${uuid}" "$(basename "${jobdir}")" \
    "submit prints the job UUID (the job directory name)"

# --wait should have blocked until completion; guard against output-flush lag.
for _ in $(seq 1 30); do
    [[ -s "${jobdir}/.stdout" ]] && break
    sleep 1
done

# --------------------------------------------------------------------------
# The job ran to completion on the selected queue.
# --------------------------------------------------------------------------
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM jobs WHERE id='${uuid}';" \
    "1" \
    "jobs table has a row for this job UUID"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${uuid}';" \
    "completed" \
    "jobs row advanced to completed after the --wait job finished"

# The row records the RESOLVED concrete queue, not the literal "auto" the default
# supplied (queue selection is written back into the row after recording).
check_sqlite ".knit/knit.db" \
    "SELECT queue FROM jobs WHERE id='${uuid}';" \
    "${REAL_QUEUE}" \
    "jobs row records the resolved concrete queue (not 'auto')"

# --------------------------------------------------------------------------
# Automatic selection resolved "auto" to the concrete real queue and wrote it
# into the batch script's directives — skipping the one-node decoy.
# --------------------------------------------------------------------------
check_grep "${QUEUE_DIRECTIVE}${REAL_QUEUE}" "${jobdir}/.job.sh" \
    "batch script requests the auto-selected real queue (${REAL_QUEUE})"

if grep -q -- "${QUEUE_DIRECTIVE}solo" "${jobdir}/.job.sh"; then
    fail "auto must skip the one-node decoy queue 'solo' for a two-node job"
else
    __assert_pass "batch script does not reference the decoy queue 'solo'"
fi

# The frozen submission metadata records the concrete resolved queue, not "auto".
check_grep "^opt:queue=${REAL_QUEUE}$" "${jobdir}/.submit" \
    ".submit metadata froze the concrete resolved queue"

# --------------------------------------------------------------------------
# The job actually ran on a compute node.
# --------------------------------------------------------------------------
check_file "${jobdir}/.stdout" "job stdout captured"
check_grep "hostname: ${NODE_PREFIX}" "${jobdir}/.stdout" \
    "job ran on a compute node"

assert_summary
