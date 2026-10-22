#!/usr/bin/env bash
# Integration test 39_sweep.
#
# Exercises `knit sweep` against the real cluster scheduler, end to end:
#   - an ephemeral `-- submit` sweep launches one job per point in the product,
#     each lands in the group and completes, and each records a provenance "call"
#     edge back to the sweeps row;
#   - a durable `-- prepare` sweep writes one prepared job per point (running
#     none), which a following `submit drain` releases to completion;
#   - `--fill sweep` draws a parameter's values from its declared --domain;
#   - `--dry-run` prints the reconstructed lines and records nothing.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/39_sweep/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/39-sweep-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/39_sweep/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-39"
SQLITE="${WORKDIR}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQLITE}"
DB="${WORKDIR}/.knit/knit.db"

# @fn count_state()
# Number of jobs in a given state within one group.
count_state() {
    "${SQLITE}" "${DB}" \
        "SELECT count(*) FROM jobs WHERE \"group\"='$1' AND state='$2';"
}

# @fn group_count()
# Number of jobs in one group (any state).
group_count() {
    "${SQLITE}" "${DB}" "SELECT count(*) FROM jobs WHERE \"group\"='$1';"
}

# ==========================================================================
# 1. An ephemeral `-- submit` sweep submits one job per point and completes.
# ==========================================================================
# Three points (--n over {1,2,4}); --parallel 3 keeps all in flight so the loop
# does not serialize the (fast) jobs behind one another's scheduling latency.
./experiment.sh sweep --group eph --parallel 3 -- submit -- sim --n '{1,2,4}'
check_eq "$(group_count eph)" "3" "the ephemeral sweep submitted one job per point"
check_eq "$(count_state eph completed)" "3" "every swept job completed"

# The sweep recorded a sweeps row; each child carries a call edge back to it.
SID="$("${SQLITE}" "${DB}" "SELECT id FROM sweeps WHERE \"group\"='eph';")"
check_eq \
    "$("${SQLITE}" "${DB}" "SELECT count(*) FROM __provenance__ WHERE source_id='${SID}' AND edge_type='call';")" \
    "3" "each swept job carries a call edge to the sweeps row"

# ==========================================================================
# 2. A durable `-- prepare` sweep prepares the product; drain runs it.
# ==========================================================================
./experiment.sh sweep --group dur -- prepare -- sim --n '{1,2,4}'
check_eq "$(count_state dur prepared)" "3" "the durable sweep prepared one job per point"
check_eq "$(count_state dur completed)" "0" "the durable sweep ran nothing yet"

./experiment.sh submit drain --group dur --max-inflight 2
check_eq "$(count_state dur completed)" "3" "draining the prepared product ran every job"
check_eq "$(count_state dur prepared)" "0" "the prepared queue drained empty"

# ==========================================================================
# 3. --fill sweep draws the parameter's values from its declared domain.
# ==========================================================================
./experiment.sh sweep --group fs --parallel 3 --fill sweep -- submit -- sim
check_eq "$(group_count fs)" "3" "--fill sweep used the declared {1,2,4} domain"
check_eq "$(count_state fs completed)" "3" "every domain-swept job completed"

# ==========================================================================
# 4. --dry-run prints the reconstructed lines and records nothing.
# ==========================================================================
BEFORE="$("${SQLITE}" "${DB}" "SELECT count(*) FROM sweeps;")"
LINES="$(./experiment.sh sweep --dry-run -- submit -- sim --n '{1,2,4}' | grep -c '^submit ')"
check_eq "${LINES}" "3" "--dry-run printed one reconstructed line per point"
check_eq "$("${SQLITE}" "${DB}" "SELECT count(*) FROM sweeps;")" "${BEFORE}" \
    "--dry-run recorded no sweeps row"

assert_summary
