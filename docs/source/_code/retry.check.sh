#!/usr/bin/env bash
# Driver for retry.sh (not shown in the documentation). Bootstraps the experiment
# and exercises the resumable prepare -> drain -> retry lifecycle on the local
# backend: prepare a batch, drain it (one job fails), re-queue the failed job with
# `submit drain --retry`, confirm it completes on the retry and the attempt is
# counted, then show the standalone `job reset` and the `--max-retries` cap.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project retry >/dev/null

# @fn sql()
# Run one read-only query and strip surrounding whitespace.
sql() {
    exp query sql --exec "$1" 2>/dev/null | tr -d '[:space:]'
}

# @fn state_of()
# The recorded lifecycle state of one job id.
state_of() {
    sql "SELECT state FROM jobs WHERE id='$1'"
}

# @fn retries_of()
# The recorded retries count of one job id (NULL prints as empty).
retries_of() {
    sql "SELECT retries FROM jobs WHERE id='$1'"
}

# ---- prepare a batch, then drain it (one job fails) -----------------------
good="$(exp prepare --group sweep -- sim --n 3)"
bad="$(exp prepare --group sweep -- flaky)"
check_eq "$(sql "SELECT count(*) FROM jobs WHERE state='prepared' AND \"group\"='sweep'")" \
    "2" "two jobs prepared in the sweep group"

# A first drain pass: the sim job completes, the flaky job fails its first run.
# Drain exits non-zero when a released job failed, which is fine here.
exp submit drain --group sweep >/dev/null 2>&1 || true
check_eq "$(state_of "${good}")" "completed" "the sim job completed on the first pass"
check_eq "$(state_of "${bad}")" "failed" "the flaky job failed on its first attempt"
check_eq "$(retries_of "${bad}")" "0" "the failed job has not been retried yet"

# ---- resume with --retry: re-queue the failed job and run it again --------
# This is the pattern a re-submitted pilot uses: re-queue whatever a previous
# pass left failed/killed, then drain. The reset is a one-shot snapshot taken at
# the start of the pass.
exp submit drain --group sweep --retry failed >/dev/null 2>&1 || true
check_eq "$(state_of "${bad}")" "completed" "the flaky job completed on the retry"
check_eq "$(retries_of "${bad}")" "1" "the retry was counted in the retries column"
check_eq "$(state_of "${good}")" "completed" "the already-completed job was untouched"

# ---- standalone job reset re-queues a terminal job ------------------------
# `job reset` is the building block `--retry` reuses: it moves a killed/failed job
# back to prepared (clearing the stale run), so a later `submit drain` re-runs it.
redo="$(exp prepare --group again -- flaky)"
exp submit drain --group again >/dev/null 2>&1 || true
check_eq "$(state_of "${redo}")" "failed" "the flaky job failed once in the again group"
exp job reset --group again >/dev/null
check_eq "$(state_of "${redo}")" "prepared" "job reset re-queued the failed job to prepared"
check_eq "$(retries_of "${redo}")" "1" "job reset counted the attempt"
exp submit drain --group again >/dev/null 2>&1 || true
check_eq "$(state_of "${redo}")" "completed" "the re-queued job completed on the retry"

# ---- --max-retries refuses to reset a job already at the cap --------------
# A job that keeps failing would retry forever; --max-retries caps it. The "again"
# job has retries=1 after the reset above, so a further reset capped at 1 is
# refused (1 >= 1): the retries count does not advance. (It is completed now, so
# --state completed --force is needed just to make it eligible for the attempt.)
exp job reset --group again --state completed --force --max-retries 1 >/dev/null 2>&1 || true
check_eq "$(retries_of "${redo}")" "1" "a reset at the cap is refused (retries unchanged)"
check_eq "$(state_of "${redo}")" "completed" "the capped job is left in place"

dc_summary
