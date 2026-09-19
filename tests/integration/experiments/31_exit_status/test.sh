#!/usr/bin/env bash
# Integration test 31_exit_status.
#
# Verifies exit-status recording and `remove --failed` on a real scheduler with a
# real MPI launcher:
#
#   - A plain command records its exit status in the reserved __exit_status__
#     column: a failure keeps its row with the non-zero code, a success records 0.
#   - A failing (non-opt-out) app records __exit_status__ on both the eager runs
#     row and rank 0's per-app row; a successful run records 0.
#   - `remove --failed --from-root` erases every failed invocation and the whole
#     job lineage that contains a failed run, while the clean work survives.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/31_exit_status/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/31-exit-status-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/31_exit_status/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-31"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

# ==========================================================================
# 1. A plain command records its exit status; a failure keeps its row.
# ==========================================================================
./experiment.sh boom --code 5 || true
./experiment.sh boom --code 0

check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM boom;" "2" \
    "both boom invocations recorded a row (the failure is kept)"
check_sqlite ".knit/knit.db" \
    "SELECT __exit_status__ FROM boom WHERE __exit_status__ <> 0;" "5" \
    "the failed boom recorded its non-zero exit code"
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM boom WHERE __exit_status__ = 0;" "1" \
    "the successful boom recorded exit status 0"

# ==========================================================================
# 2. A failing app records __exit_status__ on the runs row and the per-app row.
# ==========================================================================
fail_uuid=$(./experiment.sh submit --nodes 1 --wait -- runjob --mode fail)
fail_dir="${WORKDIR}/jobs/${fail_uuid}"
check_dir "${fail_dir}" "failed-run job directory created"

# Rank 0's per-app row keeps the exact code its body returned.
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM rank;" "1" \
    "the failed app recorded exactly one per-app row"
check_sqlite ".knit/knit.db" \
    "SELECT __exit_status__ FROM rank;" "7" \
    "the failed app recorded its exit code on the per-app row"
# The eager runs row records the launcher's non-zero status (its exact value is
# launcher-dependent, so only its non-zeroness is asserted).
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM runs;" "1" \
    "the failed run kept its eager runs row"
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM runs WHERE __exit_status__ <> 0;" "1" \
    "the failed run recorded a non-zero exit status on the runs row"

# ==========================================================================
# 3. A successful run records exit status 0.
# ==========================================================================
ok_uuid=$(./experiment.sh submit --nodes 1 --wait -- runjob --mode ok)
ok_dir="${WORKDIR}/jobs/${ok_uuid}"
check_dir "${ok_dir}" "ok-run job directory created"

check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM runs;" "2" \
    "the successful run added a second runs row"
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM runs WHERE __exit_status__ = 0;" "1" \
    "the successful run recorded exit status 0"
check_sqlite ".knit/knit.db" \
    "SELECT __exit_status__ FROM rank ORDER BY __exit_status__;" "0
7" \
    "the app table holds one successful (0) and one failed (7) per-app row"

# ==========================================================================
# 4. remove --failed alone refuses (safe default): a failed run sits under a
#    kept job, so removing the callee while its caller stays is refused and the
#    user is steered to --from-root. Nothing is deleted.
# ==========================================================================
out="$(./experiment.sh remove --failed --dry-run 2>&1 || true)"
check_grep "from-root" <(printf '%s' "${out}") \
    "remove --failed refuses a failed run under a kept job and points at --from-root"
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM boom;" "2" \
    "the refused remove --failed deleted nothing"

# ==========================================================================
# 5. remove --failed --from-root previews then erases the failures and their
#    whole job lineage; the clean work survives.
# ==========================================================================
out="$(./experiment.sh remove --failed --from-root --dry-run 2>&1)"
check_grep "boom" <(printf '%s' "${out}") "dry-run lists the failed plain command"
check_grep "rank" <(printf '%s' "${out}") "dry-run lists the failed app"
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM boom;" "2" \
    "dry-run deleted nothing"

./experiment.sh remove --failed --from-root --yes >/dev/null

# The failed plain command is gone; the successful one survives.
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM boom;" "1" \
    "remove --failed erased the failed plain command"
check_sqlite ".knit/knit.db" \
    "SELECT __exit_status__ FROM boom;" "0" \
    "the surviving plain command row is the successful one"

# The whole failed job lineage is gone; only the ok job's run and app survive.
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM jobs;" "1" \
    "the failed job was erased, the ok job survives"
check_sqlite ".knit/knit.db" "SELECT id FROM jobs;" "${ok_uuid}" \
    "the surviving job is the ok job"
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM runs;" "1" \
    "only the successful run survives"
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM rank;" "1" \
    "only the successful per-app row survives"

# No failed invocation remains anywhere.
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM runs WHERE __exit_status__ <> 0;" "0" \
    "no failed run remains"
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM rank WHERE __exit_status__ <> 0;" "0" \
    "no failed app row remains"

# The failed job's directory is gone; the ok job's directory stays.
if [[ -e "${fail_dir}" ]]; then
    fail "the failed job directory was removed"
else
    __assert_pass "the failed job directory was removed"
fi
check_dir "${ok_dir}" "the ok job directory survives"

assert_summary
