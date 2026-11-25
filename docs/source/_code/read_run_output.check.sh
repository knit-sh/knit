#!/usr/bin/env bash
# Driver for read_run_output.sh (not shown in the documentation). Bootstraps the
# experiment and runs the "evaluate" job, which launches the "train" app with
# `knit run` and reads the app's recorded accuracy back through the run handle.
# Asserts the job logged the read-back metric (so KNIT_LAST_RUN_UUID/TABLE really
# addressed the app row) and that the generic handle named the "runs" row.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project read-run-output >/dev/null

uuid=$(exp submit --wait -- evaluate)
out="$(cat "jobs/${uuid}/.stdout")"

check_contains "${out}" "the train app recorded accuracy=0.9" \
    "the job read the app's accuracy back via KNIT_LAST_RUN_UUID/TABLE"
check_contains "${out}" "the launch is runs row " \
    "the generic handle named the runs row after knit run"

# The handle really pointed at the app's own table, not the runs table: the app
# row carries the metric, and its id differs from the runs row id.
app_id=$(exp query sql --exec "SELECT id FROM train" 2>/dev/null | tr -d '[:space:]')
runs_id=$(exp query sql --exec "SELECT id FROM runs" 2>/dev/null | tr -d '[:space:]')
check_eq "$(exp query sql --exec "SELECT accuracy FROM train WHERE id='${app_id}'" \
    2>/dev/null | tr -d '[:space:]')" "0.9" \
    "the app row in the app's own table carries the recorded accuracy"
distinct=no
[[ -n "${app_id}" && "${app_id}" != "${runs_id}" ]] && distinct=yes
check_eq "${distinct}" "yes" "the app row id is distinct from the runs row id"

dc_summary
