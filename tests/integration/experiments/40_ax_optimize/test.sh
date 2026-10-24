#!/usr/bin/env bash
# Integration test 40_ax_optimize.
#
# Exercises the knit-ax Bayesian-optimization plugin end to end against the real
# cluster scheduler:
#   - "ax prepare" records a campaign (its optimizations row and campaigns/<name>/
#     directory) without running anything;
#   - "ax optimize" builds a real Ax (via the plugin's private uv-backed
#     _ax-driver environment) and runs the ask -> submit -> collect -> observe
#     loop, launching one genuine job per trial, converging on the known optimum
#     of a closed-form surrogate and recording the best on the campaign row and on
#     disk;
#   - each trial carries a provenance "call" edge back to the campaign row;
#   - an interrupted campaign resumes from its persisted state and runs to budget.
#
# This test installs ax-platform into a knit-private uv environment on first
# "ax optimize" (a CPU-only wheel set — no GPU needed, but a large download), so
# it is the heaviest experiment in the suite. The surrogate objective itself is
# just arithmetic, so the trials are fast once Ax is built.
#
# Needs network access (github.com for the plugin fetch, PyPI for ax-platform).
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/40_ax_optimize/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

EXP_DIR="/shared/knit/tests/integration/experiments/40_ax_optimize"

WORKDIR=$(mktemp -d /shared/runs/40-ax-optimize-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp "${EXP_DIR}/experiment.sh" "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap. knit_import runs at source time, so the ax (and transitively uv)
# plugin is fetched here; the private _ax-driver setup declares a uv environment,
# so bootstrap auto-provisions the knit-private uv (no --uv needed).
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-40"
SQLITE="${WORKDIR}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQLITE}"
DB="${WORKDIR}/.knit/knit.db"
# Use the jq bootstrap provisioned, not a system one (the login node may lack it).
JQ="${WORKDIR}/.knit/jq/bin/jq"

check_file ".knit/uv/bin/uv" \
    "bootstrap auto-provisioned the private uv (the _ax-driver setup requires it)"

# @fn count_state()
# Number of trial jobs in a given campaign group that reached a given state.
count_state() {
    "${SQLITE}" "${DB}" \
        "SELECT count(*) FROM jobs WHERE \"group\"='$1' AND state='$2';"
}

# @fn group_count()
# Number of trial jobs stamped with a campaign group (any state).
group_count() {
    "${SQLITE}" "${DB}" "SELECT count(*) FROM jobs WHERE \"group\"='$1';"
}

# @fn call_edges()
# Number of provenance "call" edges a campaign row (id == campaign name) carries.
call_edges() {
    "${SQLITE}" "${DB}" \
        "SELECT count(*) FROM __provenance__ WHERE source_id='$1' AND edge_type='call';"
}

# ==========================================================================
# 1. A full campaign converges on the known optimum (x = 6, score 100).
# ==========================================================================
# Five trials, two quasi-random before the GP engages; a fixed seed makes the
# run reproducible. This first "ax optimize" also builds the private Ax env.
./experiment.sh ax prepare --campaign conv --objective score --maximize \
    --trials 5 --sobol-trials 2 --seed 1 --parallel 1 -- submit -- quad --x @sweep

check_dir "campaigns/conv" "prepare created the campaign directory"
check_sqlite "${DB}" \
    "SELECT status FROM optimizations WHERE id='conv';" \
    "prepared" \
    "prepare recorded the optimizations row as prepared"

./experiment.sh ax optimize --campaign conv

# The campaign is marked completed in both places it lives.
check_eq "$(cat campaigns/conv/status)" "completed" \
    "optimize marked the campaign completed on disk"
check_file "campaigns/conv/state.json" "optimize left a resumable state.json"
check_file "campaigns/conv/result.json" "optimize wrote result.json"
check_sqlite "${DB}" \
    "SELECT status FROM optimizations WHERE id='conv';" \
    "completed" \
    "optimize marked the optimizations row completed"

# Every trial ran as a genuine job in the campaign group and completed.
check_eq "$(group_count conv)" "5" "optimize submitted one job per trial"
check_eq "$(count_state conv completed)" "5" "every trial job completed"

# The campaign row carries a resolved best_id and a sensible best_objective.
check_sqlite "${DB}" \
    "SELECT (best_id IS NOT NULL AND best_id <> '') FROM optimizations WHERE id='conv';" \
    "1" \
    "the campaign row resolved a best_id"

BEST_OBJ="$("${SQLITE}" "${DB}" "SELECT best_objective FROM optimizations WHERE id='conv';")"
if awk -v v="${BEST_OBJ}" 'BEGIN { exit !(v + 0 >= 75) }'; then
    __assert_pass "best_objective ${BEST_OBJ} is near the optimum (>= 75, max is 100)"
else
    fail "best_objective ${BEST_OBJ} did not approach the optimum (expected >= 75)"
fi

# The best trial's recorded x knob sits near the true optimum x = 6. best_id is
# the submit (jobs) row id; the x/score live in the quad body row one "call" edge
# away (the submit -> submit:quad edge), so resolve x by that two-hop walk --
# exactly how the plugin reads the objective -- rather than by best_id directly.
BEST_ID="$("${SQLITE}" "${DB}" "SELECT best_id FROM optimizations WHERE id='conv';")"
BEST_X="$("${SQLITE}" "${DB}" "SELECT x FROM quad WHERE id='${BEST_ID}' OR id IN (SELECT target_id FROM __provenance__ WHERE source_id='${BEST_ID}' AND edge_type='call');")"
if awk -v x="${BEST_X}" 'BEGIN { d = x - 6; if (d < 0) d = -d; exit !(d <= 3) }'; then
    __assert_pass "the best trial's x=${BEST_X} is near the optimum x=6 (|x-6| <= 3)"
else
    fail "the best trial's x=${BEST_X} is far from the optimum x=6"
fi

# result.json mirrors the full budget and the best objective.
check_eq "$("${JQ}" -r '.trials_done' campaigns/conv/result.json)" "5" \
    "result.json records the full trial budget"

# Each trial carries a provenance "call" edge back to the campaign row. With
# --parallel 1 and no interruption, there is exactly one edge per trial.
check_eq "$(call_edges conv)" "5" \
    "each trial carries a call edge back to the campaign row"

# ==========================================================================
# 2. An interrupted campaign resumes from its persisted state and reaches budget.
# ==========================================================================
# The Ax env is built now, so this optimize starts trialing immediately. Run it
# in the background, let it persist at least one trial (state.json appears after
# the first observation), then interrupt it and resume.
./experiment.sh ax prepare --campaign rez --objective score --maximize \
    --trials 4 --sobol-trials 2 --seed 2 --parallel 1 -- submit -- quad --x @sweep

./experiment.sh ax optimize --campaign rez &
OPT_PID=$!

# Wait for the first persisted checkpoint (up to five minutes; the surrogate
# trials are fast but go through the real scheduler).
state_ready="false"
for _ in $(seq 1 300); do
    if [[ -f campaigns/rez/state.json ]]; then
        state_ready="true"
        break
    fi
    # Stop early if the background run finished on its own.
    kill -0 "${OPT_PID}" 2>/dev/null || break
    sleep 1
done

# Interrupt the background run (its EXIT trap shuts the Ax coprocess down).
kill "${OPT_PID}" 2>/dev/null || true
wait "${OPT_PID}" 2>/dev/null || true

check_eq "${state_ready}" "true" \
    "the interrupted campaign persisted a resumable state.json before the kill"
PARTIAL_DONE="$("${JQ}" -r '.trials_done // 0' campaigns/rez/result.json 2>/dev/null || echo 0)"

# Resume: a second "ax optimize" reads the persisted state and runs the remaining
# budget to completion (or no-ops if the background run already reached budget).
./experiment.sh ax optimize --campaign rez

check_eq "$(cat campaigns/rez/status)" "completed" \
    "the resumed campaign completed"
check_eq "$("${JQ}" -r '.trials_done' campaigns/rez/result.json)" "4" \
    "the resumed campaign reached the full budget"

# The resumed run converged too, and every told trial kept its call edge (an
# interrupted in-flight trial may add one more, so assert at least the budget).
REZ_OBJ="$("${SQLITE}" "${DB}" "SELECT best_objective FROM optimizations WHERE id='rez';")"
if awk -v v="${REZ_OBJ}" 'BEGIN { exit !(v + 0 >= 50) }'; then
    __assert_pass "the resumed campaign's best_objective ${REZ_OBJ} is sensible (>= 50)"
else
    fail "the resumed campaign's best_objective ${REZ_OBJ} is not sensible"
fi
if [[ "$(call_edges rez)" -ge 4 ]]; then
    __assert_pass "the resumed campaign carries a call edge for every trial (>= 4)"
else
    fail "the resumed campaign is missing trial call edges (got $(call_edges rez))"
fi

printf 'resume: %s trials persisted before interrupt, %s after resume\n' \
    "${PARTIAL_DONE}" "4"

assert_summary
