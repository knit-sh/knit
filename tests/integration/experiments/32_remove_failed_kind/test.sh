#!/usr/bin/env bash
# Integration test 32_remove_failed_kind.
#
# Verifies the composable per-kind `remove <kind> --failed` filter on a real
# scheduler with a real MPI launcher:
#
#   - `remove command --failed` erases only the failed plain command and leaves
#     the failed run/app of another kind untouched (the isolation the top-level
#     `remove --failed` cannot give).
#   - `remove run --failed` maps a failed APP body up to its runs launch row via
#     the real `run -> run:<app>` call edge: on its own it is refused (the failed
#     run sits under a kept job), and `--from-root` erases the run and its job.
#   - A tolerated failure (a job whose body returned 0) is not a failed job, so
#     the ok job's run survives throughout.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/32_remove_failed_kind/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/32-remove-failed-kind-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/32_remove_failed_kind/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-32"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

# --------------------------------------------------------------------------
# Record failures across two kinds: a plain command and a run inside a job.
# --------------------------------------------------------------------------
./experiment.sh boom --code 5 || true
./experiment.sh boom --code 0

fail_uuid=$(./experiment.sh submit --nodes 1 --wait -- runjob --mode fail)
ok_uuid=$(./experiment.sh submit --nodes 1 --wait -- runjob --mode ok)
fail_dir="${WORKDIR}/jobs/${fail_uuid}"
ok_dir="${WORKDIR}/jobs/${ok_uuid}"

check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM boom;" "2" \
    "both boom invocations recorded a row"
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM boom WHERE __exit_status__ <> 0;" "1" \
    "one boom row is a recorded failure"
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM rank WHERE __exit_status__ <> 0;" "1" \
    "one per-app row is a recorded failure"
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM jobs;" "2" \
    "both jobs recorded a submission"

# ==========================================================================
# 1. remove command --failed erases ONLY the failed plain command; the failed
#    run and app of another kind are left untouched (per-kind isolation).
# ==========================================================================
out="$(./experiment.sh remove command --failed --dry-run 2>&1)"
check_grep "boom" <(printf '%s' "${out}") \
    "remove command --failed lists the failed plain command"
if grep -q "rank" <(printf '%s' "${out}"); then
    fail "remove command --failed must not list the failed app"
else
    __assert_pass "remove command --failed does not touch the failed app"
fi

./experiment.sh remove command --failed --yes >/dev/null
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM boom;" "1" \
    "remove command --failed erased the failed plain command"
check_sqlite ".knit/knit.db" "SELECT __exit_status__ FROM boom;" "0" \
    "the surviving plain command is the successful one"
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM rank WHERE __exit_status__ <> 0;" "1" \
    "the failed app row is untouched by remove command --failed"
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM jobs;" "2" \
    "both jobs are untouched by remove command --failed"

# ==========================================================================
# 2. remove run --failed alone is refused: the failed run sits under a kept job,
#    so removing the callee while its caller stays points at --from-root.
# ==========================================================================
out="$(./experiment.sh remove run --failed --dry-run 2>&1 || true)"
check_grep "from-root" <(printf '%s' "${out}") \
    "remove run --failed refuses a failed run under a kept job and points at --from-root"
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM runs;" "2" \
    "the refused remove run --failed deleted nothing"

# ==========================================================================
# 3. remove run --failed --from-root erases the failed run and its whole job
#    lineage (mapped up the run -> run:<app> call edge from the failed app body);
#    the tolerated (ok) run and its job survive.
# ==========================================================================
out="$(./experiment.sh remove run --failed --from-root --dry-run 2>&1)"
check_grep "rank" <(printf '%s' "${out}") \
    "dry-run lists the failed app row pulled in with the run"
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM runs;" "2" \
    "dry-run deleted nothing"

./experiment.sh remove run --failed --from-root --yes >/dev/null

check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM runs;" "1" \
    "only the successful run survives"
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM runs WHERE __exit_status__ <> 0;" "0" \
    "no failed run remains"
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM rank;" "1" \
    "only the successful per-app row survives"
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM jobs;" "1" \
    "the failed run's job was erased, the ok job survives"
check_sqlite ".knit/knit.db" "SELECT id FROM jobs;" "${ok_uuid}" \
    "the surviving job is the ok job"

# The failed job's directory is gone; the ok job's directory stays.
if [[ -e "${fail_dir}" ]]; then
    fail "the failed run's job directory was removed"
else
    __assert_pass "the failed run's job directory was removed"
fi
check_dir "${ok_dir}" "the ok job directory survives"

assert_summary
