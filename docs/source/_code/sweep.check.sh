#!/usr/bin/env bash
# Driver for sweep.sh (not shown in the documentation). Bootstraps on the local
# backend and drives both sweep forms end to end: the ephemeral `-- submit` loop
# and the durable `-- prepare` + `submit drain` queue, plus --fill sweep (drawing
# values from the declared domain) and --dry-run (prints, records nothing).
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project sweep-demo --scheduler local >/dev/null

# @fn sql()
# Run one read-only query and strip surrounding whitespace.
sql() {
    exp query sql --exec "$1" 2>/dev/null | tr -d '[:space:]'
}

# ---- ephemeral: submit one job per point in the product -------------------
# `-- submit` launches each point in-process through the search loop. The local
# backend runs each job synchronously, so all three complete.
exp sweep --group eph -- submit -- sim --n '{1,2,4}' >/dev/null 2>&1 || true
check_eq "$(sql "SELECT count(*) FROM jobs WHERE \"group\"='eph'")" "3" \
    "the ephemeral sweep submitted one job per value"
check_eq "$(sql "SELECT count(*) FROM jobs WHERE \"group\"='eph' AND state='completed'")" "3" \
    "every swept job completed"

# The sweep recorded a sweeps row, and each child carries a call edge back to it
# (ordinary provenance -- no new edge type).
sid="$(sql "SELECT id FROM sweeps WHERE \"group\"='eph'")"
check_eq "$(sql "SELECT count(*) FROM __provenance__ WHERE source_id='${sid}' AND edge_type='call'")" \
    "3" "each swept job carries a call edge to the sweeps row"

# ---- --fill sweep draws values from the parameter's declared domain -------
exp sweep --group fs --fill sweep -- submit -- sim >/dev/null 2>&1 || true
check_eq "$(sql "SELECT count(*) FROM jobs WHERE \"group\"='fs'")" "3" \
    "--fill sweep used the declared domain {1,2,4}"

# ---- durable: prepare the whole product, then drain it --------------------
# `-- prepare` writes one prepared row per point and runs nothing; a separate
# `submit drain` releases them (resumable, retryable).
exp sweep --group dur -- prepare -- sim --n '{1,2,4}' >/dev/null
check_eq "$(sql "SELECT count(*) FROM jobs WHERE \"group\"='dur' AND state='prepared'")" "3" \
    "the durable sweep prepared one job per value, running none"
exp submit drain --group dur >/dev/null 2>&1 || true
check_eq "$(sql "SELECT count(*) FROM jobs WHERE \"group\"='dur' AND state='completed'")" "3" \
    "draining the prepared product ran every job"

# ---- --dry-run prints the reconstructed lines and records nothing ---------
before="$(sql "SELECT count(*) FROM sweeps")"
out="$(exp sweep --dry-run -- submit -- sim --n '{1,2,4}')"
check_eq "$(printf '%s\n' "${out}" | grep -c '^submit ')" "3" \
    "--dry-run printed one reconstructed line per point"
check_eq "$(sql "SELECT count(*) FROM sweeps")" "${before}" \
    "--dry-run recorded no sweeps row"

dc_summary
