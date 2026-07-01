#!/usr/bin/env bash
# Integration test 03_submit_basic.
#
# Exercises the full submission pipeline against the cluster scheduler:
#   - knit bootstrap
#   - knit setup (produces .activate.sh with an exported variable)
#   - knit submit --wait: generates the batch script, dispatches it to the
#     scheduler, the job runs on a compute node, re-hydrates the setup
#     environment, and writes its stdout to <jobdir>/.stdout
#   - the job directory records .job.sh / .job.id / .job.meta
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/03_submit_basic/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/03-submit-basic-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/03_submit_basic/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap + setup
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-03"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

./experiment.sh setup --path "${WORKDIR}/env" -- env
check_file "env/.activate.sh" "setup produced .activate.sh"

# --------------------------------------------------------------------------
# Submit the job and block until it completes
# --------------------------------------------------------------------------
./experiment.sh submit --setup "${WORKDIR}/env" --wait -- hello

# --------------------------------------------------------------------------
# Locate the job directory (env/jobs/<uuid>)
# --------------------------------------------------------------------------
jobdir=$(find "${WORKDIR}/env/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "${jobdir}" ]] || fail "no job directory created under env/jobs"

# --wait should have blocked until completion, but guard against output-flush
# lag by polling briefly for a non-empty .stdout.
for _ in $(seq 1 30); do
    [[ -s "${jobdir}/.stdout" ]] && break
    sleep 1
done

# --------------------------------------------------------------------------
# Assertions: recording artifacts
# --------------------------------------------------------------------------
check_file "${jobdir}/.job.sh"   "batch script generated"
check_file "${jobdir}/.job.id"   "scheduler job id recorded"
check_file "${jobdir}/.job.meta" "job metadata recorded"
check_grep "backend=slurm" "${jobdir}/.job.meta" "job recorded the slurm backend"

# --------------------------------------------------------------------------
# Assertions: the batch script carries Slurm directives
# --------------------------------------------------------------------------
check_grep "#SBATCH --job-name=" "${jobdir}/.job.sh" \
    "batch script has the job-name directive"
check_grep "#SBATCH --exclusive" "${jobdir}/.job.sh" \
    "batch script requests whole-node exclusivity"
check_grep "#SBATCH --time=" "${jobdir}/.job.sh" \
    "batch script has the walltime directive"

# --------------------------------------------------------------------------
# Assertions: the job actually ran and captured its output
# --------------------------------------------------------------------------
check_file "${jobdir}/.stdout" "job stdout captured"
check_grep "job says: hello-from-setup" "${jobdir}/.stdout" \
    "job re-hydrated the setup environment and printed the greeting"
check_grep "hostname: slurm-compute" "${jobdir}/.stdout" \
    "job ran on a compute node"

assert_summary
