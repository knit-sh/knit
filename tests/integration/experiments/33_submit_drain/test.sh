#!/usr/bin/env bash
# Integration test 33_submit_drain.
#
# Exercises `submit drain` against the real cluster scheduler:
#   - a throttled drain (--max-inflight 2) releases a whole prepared batch to
#     completion, leaving nothing prepared;
#   - a job whose body exits non-zero lands in state "failed", and
#     `submit drain --max-inflight 1 --stop-on-failure` exits non-zero and leaves
#     the jobs after the failure still prepared;
#   - `--dry-run` lists what would be released without claiming anything.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/33_submit_drain/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/33-submit-drain-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/33_submit_drain/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-33"
SQLITE="${WORKDIR}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQLITE}"
DB="${WORKDIR}/.knit/knit.db"

# @fn state_of()
# The recorded lifecycle state of one job id (empty when the row is gone).
state_of() {
    "${SQLITE}" "${DB}" "SELECT state FROM jobs WHERE id='$1';"
}

# @fn prepared_count()
# Number of jobs in state "prepared", optionally within one group.
prepared_count() {
    local where="state='prepared'"
    [[ -n "${1:-}" ]] && where="${where} AND \"group\"='$1'"
    "${SQLITE}" "${DB}" "SELECT count(*) FROM jobs WHERE ${where};"
}

# @fn count_state()
# Number of jobs in a given state within one group.
count_state() {
    "${SQLITE}" "${DB}" \
        "SELECT count(*) FROM jobs WHERE \"group\"='$1' AND state='$2';"
}

# ==========================================================================
# 1. A throttled drain releases the whole batch to completion.
# ==========================================================================
./experiment.sh prepare --group batch -- sim --n 1 >/dev/null
./experiment.sh prepare --group batch -- sim --n 2 >/dev/null
./experiment.sh prepare --group batch -- sim --n 3 >/dev/null
./experiment.sh prepare --group batch -- sim --n 4 >/dev/null
check_eq "$(prepared_count batch)" "4" "four jobs prepared in the batch group"

./experiment.sh submit drain --group batch --max-inflight 2
check_eq "$(prepared_count batch)" "0" "submit drain --max-inflight 2 drained the batch"
check_eq "$(count_state batch completed)" "4" "every drained job completed"
check_eq "$(count_state batch failed)" "0" "no job failed in the clean batch"

# ==========================================================================
# 2. --dry-run lists what would be released without claiming anything.
# ==========================================================================
d1=$(./experiment.sh prepare --group dry -- sim --n 1)
d2=$(./experiment.sh prepare --group dry -- sim --n 2)
check_eq "$(prepared_count dry)" "2" "two jobs prepared in the dry group"

./experiment.sh submit drain --group dry --dry-run > dry.out 2>/dev/null
check_grep "${d1}" "dry.out" "dry-run lists the first prepared job"
check_grep "${d2}" "dry.out" "dry-run lists the second prepared job"
check_eq "$(prepared_count dry)" "2" "dry-run claimed nothing (group still prepared)"

# Clean the dry group up so it does not interfere with later polling.
./experiment.sh submit drain --group dry >/dev/null 2>&1

# ==========================================================================
# 3. --stop-on-failure halts on a failed job and leaves the rest prepared.
# ==========================================================================
# Prepare the failing job FIRST (prepare order is id order), then two good jobs.
fail_id=$(./experiment.sh prepare --group stop -- flaky --mode fail)
./experiment.sh prepare --group stop -- sim --n 1 >/dev/null
./experiment.sh prepare --group stop -- sim --n 2 >/dev/null
check_eq "$(prepared_count stop)" "3" "three jobs prepared in the stop group"

set +e
./experiment.sh submit drain --group stop --max-inflight 1 --stop-on-failure \
    >/dev/null 2>&1
drain_rc=$?
set -e
stop_nonzero="no"
[[ "${drain_rc}" -ne 0 ]] && stop_nonzero="yes"
check_eq "${stop_nonzero}" "yes" "submit drain --stop-on-failure exits non-zero on a failure"
check_eq "$(state_of "${fail_id}")" "failed" "the failing job's row is in state failed"
check_eq "$(prepared_count stop)" "2" "the two jobs after the failure stay prepared"

# Draining without --stop-on-failure then clears the rest (they succeed).
./experiment.sh submit drain --group stop >/dev/null 2>&1
check_eq "$(prepared_count stop)" "0" "a plain drain releases the remaining jobs"

assert_summary
