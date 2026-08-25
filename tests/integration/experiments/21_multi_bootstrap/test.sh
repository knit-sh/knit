#!/usr/bin/env bash
# Integration test 21_multi_bootstrap.
#
# Exercises re-runnable bootstrap (update mode) end to end against a real
# scheduler:
#   - knit bootstrap (first bootstrap: records the initial configuration)
#   - knit setup / knit submit --wait: record a run, so the database holds a
#     "jobs" row, a user setup exists, and the job root is non-empty
#   - knit bootstrap (update mode): a second bootstrap that
#       * updates a free field (--account),
#       * adds an AI field (--ai-model),
#       * relocates an empty path (--resource-path, no resource fetched yet),
#     changing only the options typed and leaving every other setting alone
#   - a bare re-bootstrap: a no-op that reports there is nothing to update
#   - constrained changes that must fatal WITHOUT mutating state:
#       * a changed --profile (out of scope),
#       * relocating a non-empty --job-path (a job is recorded),
#       * relocating a non-empty --setup-path (a user setup exists)
#
# Expected outcomes:
#   - the database and the earlier run survive every re-bootstrap
#   - the changed metadata keys hold their new values
#   - the untouched metadata keys keep their stored values
#   - each constrained re-bootstrap fails and leaves the stored value in place
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/21_multi_bootstrap/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/21-multi-bootstrap-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/21_multi_bootstrap/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# First bootstrap: record the initial configuration.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-21" --account "alloc-first"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__project__';" \
    "integration-test-21" \
    "first bootstrap records the project"
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__account__';" \
    "alloc-first" \
    "first bootstrap records the account"
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__resource_path__';" \
    "resources" \
    "first bootstrap records the default resource path"

# --------------------------------------------------------------------------
# Record a run: create a user setup, submit the job, block until it completes.
# This gives the experiment a "jobs" row, a user setup, and a non-empty job
# root — the state the constrained re-bootstraps below must refuse to disturb.
# --------------------------------------------------------------------------
./experiment.sh setup --name env -- env
check_file "setups/env/.activate.sh" "setup produced .activate.sh"

uuid=$(./experiment.sh submit --setup env --wait -- hello)
jobdir=$(find "${WORKDIR}/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "${jobdir}" ]] || fail "no job directory created under jobs"
for _ in $(seq 1 30); do
    [[ -s "${jobdir}/.stdout" ]] && break
    sleep 1
done

check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM jobs WHERE id='${uuid}';" \
    "1" \
    "the run is recorded as a jobs row"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${uuid}';" \
    "completed" \
    "the recorded run completed"
check_grep "job says: hello-from-setup" "${jobdir}/.stdout" \
    "the recorded run captured its output"

# --------------------------------------------------------------------------
# Update mode: a second bootstrap that changes only the options typed —
# a free field, an AI field, and an empty path — and leaves the rest alone.
# --------------------------------------------------------------------------
./experiment.sh bootstrap \
    --account "alloc-second" \
    --ai-model "gpt-test-model" \
    --resource-path "relocated-resources"

check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__account__';" \
    "alloc-second" \
    "update mode changes the typed account"
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='ai.model';" \
    "gpt-test-model" \
    "update mode adds the typed AI model"
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__resource_path__';" \
    "relocated-resources" \
    "update mode relocates the empty resource path"
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__project__';" \
    "integration-test-21" \
    "update mode leaves the untyped project unchanged"

# The database and the earlier run survive the update.
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM jobs WHERE id='${uuid}';" \
    "1" \
    "the recorded run survives update mode"

# --------------------------------------------------------------------------
# A bare re-bootstrap is a no-op that reports there is nothing to update.
# --------------------------------------------------------------------------
bare_out=$(./experiment.sh bootstrap 2>&1)
check_grep "nothing to update" <(printf '%s\n' "${bare_out}") \
    "a bare re-bootstrap reports nothing to update"
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__account__';" \
    "alloc-second" \
    "a bare re-bootstrap changes nothing"

# --------------------------------------------------------------------------
# Constrained change 1: a changed --profile is out of scope and must fatal.
# It is checked before any other option is written, so passing a second option
# alongside it proves nothing is mutated when it fails.
# --------------------------------------------------------------------------
if ./experiment.sh bootstrap --profile "some-profile" --account "alloc-bad" \
        >/dev/null 2>&1; then
    fail "re-bootstrap with a changed --profile should fail"
fi
__assert_pass "re-bootstrap with a changed --profile fails"
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__account__';" \
    "alloc-second" \
    "a rejected profile change mutates nothing"

# --------------------------------------------------------------------------
# Constrained change 2: relocating a non-empty --job-path must fatal (a job is
# recorded). Typed alone, so a mutation could only be the job path itself.
# --------------------------------------------------------------------------
if ./experiment.sh bootstrap --job-path "relocated-jobs" >/dev/null 2>&1; then
    fail "re-bootstrap relocating a non-empty --job-path should fail"
fi
__assert_pass "re-bootstrap relocating a non-empty --job-path fails"
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__job_path__';" \
    "jobs" \
    "a rejected job-path relocation leaves the stored path in place"

# --------------------------------------------------------------------------
# Constrained change 3: relocating a non-empty --setup-path must fatal (a user
# setup exists).
# --------------------------------------------------------------------------
if ./experiment.sh bootstrap --setup-path "relocated-setups" >/dev/null 2>&1; then
    fail "re-bootstrap relocating a non-empty --setup-path should fail"
fi
__assert_pass "re-bootstrap relocating a non-empty --setup-path fails"
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__setup_path__';" \
    "setups" \
    "a rejected setup-path relocation leaves the stored path in place"

# --------------------------------------------------------------------------
# Final survival check: the run, its output, and its setup are all intact after
# every re-bootstrap (both the ones that changed settings and the ones that
# failed).
# --------------------------------------------------------------------------
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${uuid}';" \
    "completed" \
    "the recorded run is still completed after every re-bootstrap"
check_file "${jobdir}/.stdout" "the recorded run's output survives"
check_dir "setups/env" "the user setup survives"

assert_summary
