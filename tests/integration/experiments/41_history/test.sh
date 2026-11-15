#!/usr/bin/env bash
# Integration test 41_history.
#
# Verifies `knit history show` on a real scheduler:
#
#   - The history records exactly the top-level commands the user invoked
#     (setup, note, submit), in time order.
#   - A submitted job's compute-side body is a non-root invocation (it carries
#     the submitter's KNIT_SOURCE_ID across the scheduler boundary), so it is
#     absent from the history; likewise the dispatched setup body.
#   - `--format bash` produces a runnable replay script of the session.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/41_history/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/41-history-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/41_history/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap, then run a small session: a setup, a plain command, and a job.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-41"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

./experiment.sh setup --name env -- env >/dev/null
./experiment.sh note --text hello >/dev/null
job_uuid=$(./experiment.sh submit --nodes 1 --wait -- greetjob)
check_dir "${WORKDIR}/jobs/${job_uuid}" "the job directory was created"

# ==========================================================================
# 1. The history records exactly the user's top-level commands, in order.
# ==========================================================================
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM __history__;" "3" \
    "exactly the three user invocations were recorded (setup, note, submit)"
check_sqlite ".knit/knit.db" \
    "SELECT command FROM __history__ ORDER BY start_time, id;" \
    "setup
note
submit" \
    "the history lists setup, note, submit in time order"

# ==========================================================================
# 2. Downstream work is excluded: the compute-side job body (greetjob) and the
#    dispatched setup body (setup:env) are non-root and must not appear.
# ==========================================================================
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM __history__ WHERE command = 'greetjob';" "0" \
    "the job's compute-side body is absent from the history (KNIT_SOURCE_ID)"
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM __history__ WHERE command LIKE 'setup:%';" "0" \
    "the dispatched setup body is absent from the history"

# ==========================================================================
# 3. The invoked form records the arguments as typed.
# ==========================================================================
check_sqlite ".knit/knit.db" \
    "SELECT invoked FROM __history__ WHERE command = 'note';" \
    '["--text","hello"]' \
    "the note invocation recorded its typed arguments"

# ==========================================================================
# 4. --format bash produces a runnable replay script of the session.
# ==========================================================================
./experiment.sh history show --format bash > replay.sh

check_grep '^#!/usr/bin/env bash$' replay.sh "the replay script starts with a shebang"
check_grep '^\./experiment\.sh note --text hello$' replay.sh \
    "the replay script replays the note command"
check_grep '^\./experiment\.sh submit --nodes 1 --wait -- greetjob$' replay.sh \
    "the replay script replays the submit command"
# The script is syntactically valid bash (it replays without being re-run here,
# which would resubmit jobs and mutate the database).
if bash -n replay.sh; then
    __assert_pass "the replay script is valid bash"
else
    fail "the replay script is not valid bash"
fi

assert_summary
