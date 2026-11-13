#!/usr/bin/env bash
# Integration test 41_ax_model.
#
# Exercises the knit-ax plugin's surrogate-model (active-learning) mode end to end
# against the real cluster scheduler:
#   - "ax prepare --model" records a model campaign (sense=model) over a mixed
#     range+choice search space, running nothing;
#   - "ax optimize" builds a real Ax and runs the ask -> submit -> collect ->
#     observe loop as active learning, launching one genuine job per trial, and
#     records NO best (a model campaign has no optimum);
#   - "ax show" reports the campaign's varying axes instead of a best;
#   - "ax predict" queries the fitted surrogate at a chosen in-space point and
#     returns a predicted value (bare, and as JSON);
#   - "ax show --diagnostics" cross-validates the surrogate and reports R^2/RMSE.
#
# Reuses the same heavy one-time Ax environment build as 40_ax_optimize.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/41_ax_model/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

EXP_DIR="/shared/knit/tests/integration/experiments/41_ax_model"

WORKDIR=$(mktemp -d /shared/runs/41-ax-model-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp "${EXP_DIR}/experiment.sh" "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

./experiment.sh bootstrap --project "integration-test-41"
SQLITE="${WORKDIR}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQLITE}"
DB="${WORKDIR}/.knit/knit.db"
JQ="${WORKDIR}/.knit/jq/bin/jq"

group_count() {
    "${SQLITE}" "${DB}" "SELECT count(*) FROM jobs WHERE \"group\"='$1';"
}
count_state() {
    "${SQLITE}" "${DB}" \
        "SELECT count(*) FROM jobs WHERE \"group\"='$1' AND state='$2';"
}

CAMP="surf-model"

# ==========================================================================
# 1. Prepare a model campaign over a mixed range+choice space.
# ==========================================================================
./experiment.sh ax prepare --campaign "${CAMP}" --objective score --model \
    --max-trials 6 --sobol-trials 3 --seed 1 \
    -- submit -- surf --x @domain --k '{1,2,3,4}'

check_dir "campaigns/${CAMP}" "prepare created the campaign directory"
check_sqlite "${DB}" \
    "SELECT sense FROM optimizations WHERE id='${CAMP}';" "model" \
    "prepare recorded the optimizations row with sense=model"
check_sqlite "${DB}" \
    "SELECT status FROM optimizations WHERE id='${CAMP}';" "prepared" \
    "prepare recorded the model campaign as prepared"

# ==========================================================================
# 2. Optimize runs the budget as active learning and records NO best.
# ==========================================================================
./experiment.sh ax optimize --campaign "${CAMP}"

check_eq "$(cat campaigns/${CAMP}/status)" "completed" \
    "optimize marked the model campaign completed"
check_file "campaigns/${CAMP}/state.json" "optimize left a resumable state.json"
check_eq "$("${JQ}" -r '.trials_done' campaigns/${CAMP}/result.json)" "6" \
    "result.json records the full trial budget"
check_eq "$(group_count ${CAMP})" "6" "optimize submitted one job per trial"
check_eq "$(count_state ${CAMP} completed)" "6" "every trial job completed"

# No optimum: best_id and best_objective stay empty/null on the row, and
# result.json carries a null best objective.
check_sqlite "${DB}" \
    "SELECT (best_id IS NULL OR best_id='') FROM optimizations WHERE id='${CAMP}';" \
    "1" "a model campaign records no best_id"
check_sqlite "${DB}" \
    "SELECT (best_objective IS NULL OR best_objective='') FROM optimizations WHERE id='${CAMP}';" \
    "1" "a model campaign records no best_objective"
check_eq "$("${JQ}" -r '.best.objective' campaigns/${CAMP}/result.json)" "null" \
    "result.json records a null best objective for a model campaign"

# ==========================================================================
# 3. "ax show" reports the axes (not a best) for a model campaign.
# ==========================================================================
SHOW_OUT="$(./experiment.sh ax show --campaign "${CAMP}")"
printf '%s\n' "${SHOW_OUT}" > show.txt
check_grep "^axes:" show.txt "ax show lists the campaign's axes"
check_grep "surf.x" show.txt "ax show names the range axis (surf.x)"
check_grep "surf.k" show.txt "ax show names the choice axis (surf.k)"
if grep -q "^best:" show.txt; then
    fail "ax show printed a best line for a model campaign"
else
    __assert_pass "ax show printed no best line for a model campaign"
fi
check_grep "(model)" show.txt "ax show marks the objective as a model campaign"

# ==========================================================================
# 4. "ax predict" queries the fitted surrogate at an in-space point.
# ==========================================================================
PRED="$(./experiment.sh ax predict --campaign "${CAMP}" \
    -- submit -- surf --x 6 --k 2)"
printf 'predict bare: %s\n' "${PRED}"
if [[ "${PRED}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    __assert_pass "ax predict returned a numeric value (${PRED})"
else
    fail "ax predict did not return a bare numeric value (got '${PRED}')"
fi

# JSON form carries mean / sem / variance / ci95.
PRED_JSON="$(./experiment.sh ax predict --campaign "${CAMP}" --json \
    -- submit -- surf --x 6 --k 2)"
printf 'predict json: %s\n' "${PRED_JSON}"
printf '%s' "${PRED_JSON}" | "${JQ}" -e '.objective=="score" and (.mean|type=="number")
    and (.sem|type=="number") and (.variance|type=="number")
    and (.ci95|length==2)' >/dev/null \
    && __assert_pass "ax predict --json has objective/mean/sem/variance/ci95" \
    || fail "ax predict --json is missing fields (got '${PRED_JSON}')"

# An out-of-space choice value is rejected.
if ./experiment.sh ax predict --campaign "${CAMP}" \
        -- submit -- surf --x 6 --k 7 >/dev/null 2>&1; then
    fail "ax predict accepted an out-of-space choice value (--k 7)"
else
    __assert_pass "ax predict rejected an out-of-space choice value (--k 7)"
fi

# ==========================================================================
# 5. "ax show --diagnostics" cross-validates the surrogate.
# ==========================================================================
DIAG="$(./experiment.sh ax show --campaign "${CAMP}" --diagnostics)"
printf '%s\n' "${DIAG}" > diag.txt
printf 'diagnostics:\n%s\n' "${DIAG}"
check_grep "diagnostics:" diag.txt "ax show --diagnostics printed a diagnostics block"
check_grep "cross-val R\^2:" diag.txt "diagnostics reports a cross-validated R^2"
check_grep "cross-val RMSE:" diag.txt "diagnostics reports a cross-validated RMSE"

assert_summary
