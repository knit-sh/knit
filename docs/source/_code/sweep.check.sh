#!/usr/bin/env bash
# Driver for sweep.sh (not shown in the documentation). Bootstraps on the local
# backend and drives both sweep forms end to end: the ephemeral `-- submit` loop
# and the durable `-- prepare` + `submit drain` queue, plus --fill domain (drawing
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
# backend runs each job synchronously, so all three complete. A --group on the
# submit line labels the jobs the sweep produces (the sweep's own --group, if
# any, would label the sweeps row instead -- the two are independent).
exp sweep -- submit --group eph -- sim --n '{1,2,4}' >/dev/null 2>&1 || true
check_eq "$(sql "SELECT count(*) FROM jobs WHERE \"group\"='eph'")" "3" \
    "the ephemeral sweep submitted one job per value"
check_eq "$(sql "SELECT count(*) FROM jobs WHERE \"group\"='eph' AND state='completed'")" "3" \
    "every swept job completed"

# The sweep recorded a sweeps row, and each child carries a call edge back to it
# (ordinary provenance -- no new edge type). The sweep finds its children by
# walking those edges, not by a shared group, so the sweeps row is reached from a
# child here rather than by a group lookup.
sid="$(sql "SELECT source_id FROM __provenance__ WHERE edge_type='call' AND target_id IN (SELECT id FROM jobs WHERE \"group\"='eph') LIMIT 1")"
check_eq "$(sql "SELECT count(*) FROM __provenance__ WHERE source_id='${sid}' AND edge_type='call'")" \
    "3" "each swept job carries a call edge to the sweeps row"

# ---- --fill domain draws values from the parameter's declared domain ------
exp sweep --fill domain -- submit --group fs -- sim >/dev/null 2>&1 || true
check_eq "$(sql "SELECT count(*) FROM jobs WHERE \"group\"='fs'")" "3" \
    "--fill domain used the declared domain {1,2,4}"

# ---- durable: prepare the whole product, then drain it --------------------
# `-- prepare` writes one prepared row per point and runs nothing; a separate
# `submit drain` releases them (resumable, retryable). The --group on prepare
# labels the prepared jobs so the later drain can select them.
exp sweep -- prepare --group dur -- sim --n '{1,2,4}' >/dev/null
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
