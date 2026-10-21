#!/usr/bin/env bash
# Driver for reconcile.sh (not shown in the documentation). Bootstraps the
# experiment and exercises the stuck-job recover lifecycle on the local backend:
# prepare a job, drain it, simulate a hard-kill by forcing its state back to
# "running", then assert that `job reconcile` moves it to a terminal state and
# that `submit drain --reconcile --retry killed` turns it back to completed.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project reconcile >/dev/null

SQLITE="./.knit/sqlite/bin/sqlite3"
DB="./.knit/knit.db"

# @fn sql()
# Run one read-only query and strip surrounding whitespace.
sql() {
    "${SQLITE}" "${DB}" "$1" | tr -d '[:space:]'
}

# @fn state_of()
# The recorded lifecycle state of one job id.
state_of() {
    sql "SELECT state FROM jobs WHERE id='$1'"
}

# @fn set_state()
# Force a job's lifecycle state directly in the database, simulating what a
# hard SIGKILL leaves behind when the kill trap cannot run.
set_state() {
    "${SQLITE}" "${DB}" "UPDATE jobs SET state='$2' WHERE id='$1';"
}

# ---- prepare and drain a job to get a real .job.id on disk ----------------
j1="$(exp prepare --group rec -- sim --n 5)"
exp submit drain --group rec >/dev/null 2>&1
check_eq "$(state_of "${j1}")" "completed" "the sim job completed normally"

# ---- simulate a hard kill: force state back to running --------------------
# A hard SIGKILL (OOM, node crash) leaves the row at "running" because the
# compute-side kill trap had no chance to fire. The .job.id file is still
# present, so reconcile can query the scheduler for the true fate.
set_state "${j1}" "running"
check_eq "$(state_of "${j1}")" "running" "state forced to running (simulated stuck job)"

# ---- job reconcile corrects the stuck row ---------------------------------
exp job reconcile --group rec >/dev/null 2>&1
# The local backend uses kill -0 to check liveness: a finished PID fails the
# check, so reconcile maps the verdict to "killed".
check_eq "$(state_of "${j1}")" "killed" "job reconcile moved the stuck row to killed"

# ---- recover with submit drain --reconcile --retry killed ------------------
# Set up a fresh stuck job to exercise the combined recover-and-retry path.
j2="$(exp prepare --group rec2 -- sim --n 3)"
exp submit drain --group rec2 >/dev/null 2>&1
check_eq "$(state_of "${j2}")" "completed" "second job completed normally"

set_state "${j2}" "running"
# A single drain pass: reconcile corrects running -> killed, retry re-queues
# killed -> prepared, then drain runs it to completion.
exp submit drain --group rec2 --reconcile --retry killed >/dev/null 2>&1
check_eq "$(state_of "${j2}")" "completed" \
    "submit drain --reconcile --retry turned stuck-running into completed"

dc_summary
