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
#   - `submit --walltime none` is rejected on a batch scheduler (no unbounded
#     jobs there) and records no row
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

# --------------------------------------------------------------------------
# A blocking `submit --wait` on a job that fails must return non-zero and record
# the row "failed" (not leave it stranded at "running"). The failer's body aborts
# with knit_fatal, which exits before the normal after-callback; the on-fatal
# recorder marks the row "failed".
# --------------------------------------------------------------------------
set +e
fail_uuid="$(./experiment.sh submit --setup env --wait -- failer 2>/dev/null)"
fail_rc=$?
set -e
wait_failed="no"
[[ "${fail_rc}" -ne 0 ]] && wait_failed="yes"
check_eq "${wait_failed}" "yes" "submit --wait returns non-zero for a failing job"
fail_state="$("${SQLITE}" ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${fail_uuid}';")"
check_eq "${fail_state}" "failed" "the failing job is recorded failed, not stranded running"

# --------------------------------------------------------------------------
# `--walltime none` asks for no wall-clock limit. A batch scheduler always runs a
# job under a queue walltime cap, so it is rejected here (this experiment runs on
# a real Slurm/PBS/Flux cluster): the submit must exit non-zero, name the limit,
# and record no new job row. (The honored local/none/pilot path is covered by the
# unit tests, where a local backend can be forced.)
rows_before="$("${SQLITE}" ".knit/knit.db" "SELECT COUNT(*) FROM jobs;")"
set +e
none_out="$(./experiment.sh submit --setup env --walltime none -- worker 2>&1)"
none_rc=$?
set -e
none_rejected="no"
[[ "${none_rc}" -ne 0 ]] && none_rejected="yes"
check_eq "${none_rejected}" "yes" "submit --walltime none is rejected on a batch scheduler"
none_msg="no"
[[ "${none_out}" == *"--walltime none is not supported"* ]] && none_msg="yes"
check_eq "${none_msg}" "yes" "the rejection names the --walltime none limitation"
rows_after="$("${SQLITE}" ".knit/knit.db" "SELECT COUNT(*) FROM jobs;")"
check_eq "${rows_after}" "${rows_before}" "the rejected submit records no job row"

assert_summary
