#!/usr/bin/env bash
# Driver for claims.sh (not shown in the documentation). Bootstraps the
# experiment, records a few samples, and exercises the claim: an insufficient
# verdict before any data, a holding and a refuted check, recording with
# --record, and the listing.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project claims >/dev/null

# Before any sample exists the claim cannot be decided: insufficient, exit 2.
out="$(exp claim check -- mean-above --floor 0 2>&1)"; rc=$?
check_eq "${rc}" "2" "an undecided claim exits with KNIT_CLAIM_INSUFFICIENT"
check_contains "${out}" "insufficient data" "insufficient verdict is noted"

# Record three samples with a positive mean (mean = 2).
exp sample --x 1 >/dev/null
exp sample --x 2 >/dev/null
exp sample --x 3 >/dev/null

# The mean (2) is at least the floor (0): holds, exit 0, green tick.
out="$(exp claim check -- mean-above --floor 0)"; rc=$?
check_eq "${rc}" "0" "a holding claim exits with KNIT_CLAIM_HOLDS"
check_contains "${out}" "✓" "a holding claim prints the tick"
check_contains "${out}" "mean 2.0 over 3 samples" "the statement interpolates the outputs"

# The mean (2) is below a floor of 5: refuted, exit 1, red cross.
out="$(exp claim check -- mean-above --floor 5)"; rc=$?
check_eq "${rc}" "1" "a refuted claim exits with KNIT_CLAIM_REFUTED"
check_contains "${out}" "✗" "a refuted claim prints the cross"

# A plain check records nothing; --record persists exactly one row.
exp claim check -- mean-above --floor 0 >/dev/null
check_eq "$(exp query sql --exec 'SELECT count(*) FROM "mean_above"')" "0" \
    "a plain check records no row"
exp claim check --record -- mean-above --floor 0 >/dev/null
check_eq "$(exp query sql --exec 'SELECT count(*) FROM "mean_above"')" "1" \
    "--record writes one row"
check_eq "$(exp query sql --exec 'SELECT __verdict__ FROM "mean_above"')" "holds" \
    "the recorded row carries the verdict"

# claim list shows the recorded finding under the claim's name.
out="$(exp claim list --type mean-above)"
check_contains "${out}" "mean-above" "claim list groups under the claim name"
check_contains "${out}" "✓" "claim list shows the recorded verdict marker"

dc_summary
