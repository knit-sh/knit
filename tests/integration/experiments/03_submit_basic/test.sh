#!/usr/bin/env bash
# Integration test 03_submit_basic.
#
# Exercises the full submission pipeline against the cluster scheduler:
#   - knit bootstrap
#   - knit setup (produces .activate.sh with an exported variable)
#   - knit submit --wait: generates the batch script, dispatches it to the
#     scheduler, the job runs on a compute node, re-hydrates the setup
#     environment, and writes its stdout to <jobdir>/.stdout
#   - the job directory records .job.sh / .job.id, and the submission is stored
#     as a row in the "jobs" table
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
# Detect which scheduler this cluster runs so the assertions match the backend
# knit will auto-detect and use.
# --------------------------------------------------------------------------
if command -v sbatch >/dev/null 2>&1; then
    BACKEND="slurm"
    NODE_PREFIX="slurm-compute"
    NAME_DIRECTIVE="#SBATCH --job-name="
    EXCL_DIRECTIVE="#SBATCH --exclusive"
    TIME_DIRECTIVE="#SBATCH --time="
elif command -v qsub >/dev/null 2>&1; then
    BACKEND="pbs"
    NODE_PREFIX="pbs-compute"
    NAME_DIRECTIVE="#PBS -N "
    EXCL_DIRECTIVE="#PBS -l place=excl"
    TIME_DIRECTIVE="#PBS -l walltime="
else
    fail "no supported scheduler (sbatch/qsub) found on the login node"
fi

# --------------------------------------------------------------------------
# Submit the job and block until it completes. submit prints the job UUID.
# --------------------------------------------------------------------------
uuid=$(./experiment.sh submit --setup "${WORKDIR}/env" --wait -- hello)

# --------------------------------------------------------------------------
# Locate the job directory (env/jobs/<uuid>)
# --------------------------------------------------------------------------
jobdir=$(find "${WORKDIR}/env/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "${jobdir}" ]] || fail "no job directory created under env/jobs"

# The value printed by submit is the job UUID, i.e. the job directory's name.
check_eq "${uuid}" "$(basename "${jobdir}")" \
    "submit prints the job UUID (the job directory name)"

# --wait should have blocked until completion, but guard against output-flush
# lag by polling briefly for a non-empty .stdout.
for _ in $(seq 1 30); do
    [[ -s "${jobdir}/.stdout" ]] && break
    sleep 1
done

# --------------------------------------------------------------------------
# Assertions: recording artifacts
# --------------------------------------------------------------------------
check_file "${jobdir}/.job.sh" "batch script generated"
check_file "${jobdir}/.job.id" "launcher job id recorded"

# The submission is recorded as one row in the "jobs" table, keyed by the
# job UUID, recording the job name. Because we submitted with --wait, the job has
# run to completion, so its lifecycle state has advanced submitted -> running ->
# completed by the compute-side callbacks (M8).
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM jobs WHERE id='${uuid}';" \
    "1" \
    "jobs table has a row for this job UUID"
check_sqlite ".knit/knit.db" \
    "SELECT job FROM jobs WHERE id='${uuid}';" \
    "hello" \
    "jobs row records the job name"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${uuid}';" \
    "completed" \
    "jobs row advanced to completed after the --wait job finished"

# --------------------------------------------------------------------------
# Assertions: the batch script carries the scheduler's directives
# --------------------------------------------------------------------------
check_grep "${NAME_DIRECTIVE}" "${jobdir}/.job.sh" \
    "batch script has the job-name directive"
check_grep "${EXCL_DIRECTIVE}" "${jobdir}/.job.sh" \
    "batch script requests whole-node exclusivity"
check_grep "${TIME_DIRECTIVE}" "${jobdir}/.job.sh" \
    "batch script has the walltime directive"

# --------------------------------------------------------------------------
# Assertions: the job actually ran and captured its output
# --------------------------------------------------------------------------
check_file "${jobdir}/.stdout" "job stdout captured"
check_grep "job says: hello-from-setup" "${jobdir}/.stdout" \
    "job re-hydrated the setup environment and printed the greeting"
check_grep "hostname: ${NODE_PREFIX}" "${jobdir}/.stdout" \
    "job ran on a compute node"

# --------------------------------------------------------------------------
# Assertions: provenance edge across the scheduler (B2)
#
# The job body runs on a compute node with no in-process caller; it reads the
# source context the batch script exported (KNIT_SOURCE_ID / KNIT_SOURCE_COMMAND)
# and records a "submit -> submit:hello" call edge. The source id is the
# submitting jobs.id (the job UUID); the target is the compute-side body's own
# fresh row id, which joins the "hello" data table and is distinct from the
# submission id.
# --------------------------------------------------------------------------
check_sqlite ".knit/knit.db" \
    "SELECT source_id, source_name FROM __provenance__ WHERE target_name='submit:hello' AND edge_type='call';" \
    "${uuid}|submit" \
    "compute-side job body edge has source (jobs.id, 'submit')"

# The body edge's target is a fresh id joining the "hello" table, not the
# submission UUID (distinct ids, linked only by the edge).
body_id=$(${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT target_id FROM __provenance__ WHERE target_name='submit:hello' AND edge_type='call';")
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM hello WHERE id='${body_id}';" \
    "1" \
    "job body edge target joins the hello data row"
if [[ "${body_id}" == "${uuid}" ]]; then
    fail "job body id must be distinct from the submission UUID"
else
    __assert_pass "job body id is distinct from the submission UUID"
fi

assert_summary
