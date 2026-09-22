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

# ---- prepare from a plan with object-form args sub-axes -------------------
exp argplan | exp prepare from >/dev/null
# nodes[2] x n[2] x label[2] = 8 combinations; the args-subset exclude names only
# label=b, so it drops those 4, leaving 4 prepared jobs.
check_eq "$(prepared_count grid)" "4" \
    "an object-form args axis expands to the product, trimmed by the subset exclude"
# The exclude named only the args sub-key label=b, so no surviving grid job
# carries --label b (job args live in the generated .job.sh, not a jobs column).
kept_b=0
while IFS= read -r gid; do
    [[ -z "${gid}" ]] && continue
    grep -q -- '--label b' "jobs/${gid}/.job.sh" && kept_b=$(( kept_b + 1 ))
done < <(exp query sql --exec \
    "SELECT id FROM jobs WHERE \"group\"='grid' AND state='prepared'" 2>/dev/null)
check_eq "${kept_b}" "0" "the args-subset exclude dropped every label=b combination"

# Clean the grid group up (prepared jobs never contacted a scheduler).
while IFS= read -r gid; do
    [[ -z "${gid}" ]] && continue
    exp job cancel --id "${gid}" >/dev/null 2>&1
done < <(exp query sql --exec \
    "SELECT id FROM jobs WHERE \"group\"='grid' AND state='prepared'" 2>/dev/null)

# ---- defaults.args deep-merges under a matrix sweep -----------------------
# label is shared through defaults.args; n is swept in the matrix args axis. A
# shallow merge would let each combination's args replace defaults.args, dropping
# the shared label; the deep merge keeps it.
printf '%s' '{ "group": "merge",
  "defaults": { "args": { "label": "shared" } },
  "jobs": [ { "matrix": { "job": "sim",
                          "axes": { "args": { "n": [1, 2] } } } } ] }' \
    | exp prepare from >/dev/null
check_eq "$(prepared_count merge)" "2" "the defaults.args sweep prepared two jobs"
kept_label=0
while IFS= read -r mid; do
    [[ -z "${mid}" ]] && continue
    grep -q -- '--label shared' "jobs/${mid}/.job.sh" && kept_label=$(( kept_label + 1 ))
done < <(exp query sql --exec \
    "SELECT id FROM jobs WHERE \"group\"='merge' AND state='prepared'" 2>/dev/null)
check_eq "${kept_label}" "2" "defaults.args.label survived the matrix sweep (deep merge)"

# ---- submit drain releases a whole batch ----------------------------------
exp prepare --group drainset -- sim --n 1 >/dev/null
exp prepare --group drainset -- sim --n 2 >/dev/null
exp prepare --group drainset -- sim --n 3 >/dev/null
check_eq "$(prepared_count drainset)" "3" "three jobs prepared for draining"

# --dry-run lists what would be released without claiming anything.
dry="$(exp submit drain --group drainset --dry-run 2>/dev/null)"
check_eq "$(printf '%s\n' "${dry}" | grep -c 'sim')" "3" \
    "submit drain --dry-run lists all three prepared jobs"
check_eq "$(prepared_count drainset)" "3" "submit drain --dry-run releases nothing"

# A throttled drain empties the group, keeping at most two jobs in flight.
exp submit drain --group drainset --max-inflight 2 >/dev/null 2>&1
check_eq "$(prepared_count drainset)" "0" "submit drain releases the whole batch"

dc_summary
