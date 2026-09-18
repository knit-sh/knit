#!/usr/bin/env bash
# Integration test 30_run_no_record.
#
# Verifies that `knit run` honors an app's knit_no_record_on_failure opt-out for
# the runs table, on a real scheduler with a real MPI launcher:
#
#   - Job "run_boom --mode fail": the boom app returns non-zero, so the launcher
#     reports failure. The dispatcher records the runs row eagerly before the
#     launch, but because the app opted out (and rank 0 therefore skipped its
#     per-app row and the run -> run:boom edge), the dispatcher removes the runs
#     row so it does not dangle. The driver asserts the runs table, the boom
#     table, and the run provenance edges are all empty afterwards.
#   - Job "run_boom --mode ok": the boom app succeeds, so a run is recorded
#     normally: exactly one runs row joined to exactly one per-app row through
#     the run -> run:boom call edge.
#
# The failed run leaves no queryable trace of the run itself, so its absence is
# asserted directly; the successful run is the positive control proving the run
# would otherwise be recorded.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/30_run_no_record/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/30-run-no-record-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/30_run_no_record/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-30"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

# ==========================================================================
# 1. Failed run of an opt-out app: no dangling runs row.
# ==========================================================================
fail_uuid=$(./experiment.sh submit --nodes 1 --wait -- run_boom --mode fail)
fail_dir="${WORKDIR}/jobs/${fail_uuid}"
check_dir "${fail_dir}" "failed-run job directory created"

# The runs row eagerly recorded before launch was removed after the failure, so
# the runs table is empty (it would otherwise hold one dangling row).
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM runs;" "0" \
    "a failed opt-out run leaves no runs row (removed, not dangling)"

# Rank 0 skipped the per-app row on failure (the pre-existing opt-out behavior).
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM boom;" "0" \
    "a failed opt-out run leaves no per-app row"

# No provenance edge references the removed run: neither the incoming
# "submit:run_boom -> run" edge (deleted with the row) nor an outgoing
# "run -> run:boom" edge (never written, since rank 0's recording was suppressed).
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM __provenance__ WHERE target_name='run' OR source_name='run';" \
    "0" \
    "no run provenance edge survives the failed opt-out run"

# ==========================================================================
# 2. Successful run of the same app: one runs row joined to one per-app row.
# ==========================================================================
ok_uuid=$(./experiment.sh submit --nodes 1 --wait -- run_boom --mode ok)
ok_dir="${WORKDIR}/jobs/${ok_uuid}"
check_dir "${ok_dir}" "ok-run job directory created"

# The opt-out suppresses only a FAILED run; a success records normally.
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM runs;" "1" \
    "a successful opt-out run records exactly one runs row"
check_sqlite ".knit/knit.db" "SELECT app FROM runs;" "boom" \
    "the runs row records the boom app"
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM boom;" "1" \
    "a successful run records exactly one per-app row"

# The run -> run:boom call edge joins the runs row to the per-app row (distinct
# ids), confirming the successful run is fully recorded and linked.
run_id=$(${__ASSERT_SQLITE3} .knit/knit.db "SELECT id FROM runs;")
app_id=$(${__ASSERT_SQLITE3} .knit/knit.db "SELECT id FROM boom;")
if [[ "${run_id}" == "${app_id}" ]]; then
    fail "the runs row id and the per-app row id must be distinct"
else
    __assert_pass "run and per-app row have distinct ids"
fi
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM __provenance__ WHERE source_id='${run_id}' AND target_id='${app_id}' AND target_name='run:boom' AND edge_type='call';" \
    "1" \
    "the run -> run:boom call edge joins the runs row to the per-app row"

assert_summary
