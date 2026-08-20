#!/usr/bin/env bash
# Driver for prepare.sh (not shown in the documentation). Bootstraps the
# experiment and exercises the whole prepare -> release lifecycle on the local
# backend: prepare with --group, list prepared jobs, drain a group with
# `submit next`, prepare a batch (including a matrix) with `prepare from`, release
# one by id, and cancel a still-prepared job.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project prepare >/dev/null

# @fn prepared_count()
# Number of jobs currently in state "prepared" (optionally in one group).
prepared_count() {
    local where="state='prepared'"
    [[ -n "${1:-}" ]] && where="${where} AND \"group\"='$1'"
    exp query sql --exec "SELECT count(*) FROM jobs WHERE ${where}" 2>/dev/null \
        | tr -d '[:space:]'
}

# @fn state_of()
# The recorded lifecycle state of one job id.
state_of() {
    exp query sql --exec "SELECT state FROM jobs WHERE id='$1'" 2>/dev/null \
        | tr -d '[:space:]'
}

# ---- prepare records rows without dispatching -----------------------------
id1="$(exp prepare --group sweep -- sim --n 5)"
id2="$(exp prepare --group sweep -- sim --n 7)"
check_eq "$(prepared_count sweep)" "2" "two jobs prepared in the group"
check_eq "$(state_of "${id1}")" "prepared" "a prepared job is in state prepared"

# job list --status prepared surfaces them (a prepared job is an ordinary row).
listed="$(exp job list --status prepared 2>/dev/null)"
check_contains "${listed}" "${id1}" "job list --status prepared shows the first job"
check_contains "${listed}" "${id2}" "job list --status prepared shows the second job"

# ---- submit next drains the group in prepare order ------------------------
first="$(exp submit next --group sweep --wait)"
check_eq "${first}" "${id1}" "submit next releases the oldest prepared job first"
check_eq "$(state_of "${id1}")" "completed" "a released job runs to completion under --wait"

exp submit next --group sweep --wait >/dev/null    # release id2
check_eq "$(prepared_count sweep)" "0" "the group is drained"

# Draining reports non-zero so a fill-the-queue loop can stop.
if exp submit next --group sweep --wait >/dev/null 2>&1; then
    check_eq "drained-returns-zero" "drained-returns-nonzero" \
        "submit next returns non-zero when nothing matches"
else
    check_eq "nonzero" "nonzero" "submit next returns non-zero when nothing matches"
fi

# ---- prepare from a plan (with a matrix) ----------------------------------
exp plan | exp prepare from >/dev/null
check_eq "$(prepared_count sweep)" "5" "prepare from expands the plan to five jobs"
# The matrix is product(2x2) - 1 exclude + 1 include: exactly one nodes=2 (the
# b/2 combination is excluded) and exactly one nodes=4 (the include).
n2="$(exp query sql --exec \
    "SELECT count(*) FROM jobs WHERE state='prepared' AND nodes='2'" 2>/dev/null \
    | tr -d '[:space:]')"
n4="$(exp query sql --exec \
    "SELECT count(*) FROM jobs WHERE state='prepared' AND nodes='4'" 2>/dev/null \
    | tr -d '[:space:]')"
check_eq "${n2}" "1" "exclude dropped the b/nodes=2 combination"
check_eq "${n4}" "1" "include appended the nodes=4 combination"

# ---- release one by id, cancel another ------------------------------------
target="$(exp query sql --exec \
    "SELECT id FROM jobs WHERE state='prepared' ORDER BY id ASC LIMIT 1" \
    2>/dev/null | tr -d '[:space:]')"
exp submit prepared --id "${target}" --wait >/dev/null
check_eq "$(state_of "${target}")" "completed" "submit prepared --id releases that job"

doomed="$(exp query sql --exec \
    "SELECT id FROM jobs WHERE state='prepared' ORDER BY id ASC LIMIT 1" \
    2>/dev/null | tr -d '[:space:]')"
exp job cancel --id "${doomed}" >/dev/null
check_eq "$(state_of "${doomed}")" "" "job cancel removes a prepared job's row"
check_eq "$([[ -e "jobs/${doomed}" ]] && echo present || echo gone)" "gone" \
    "job cancel removes a prepared job's directory"

dc_summary
