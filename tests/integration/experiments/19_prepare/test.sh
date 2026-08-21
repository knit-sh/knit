#!/usr/bin/env bash
# Integration test 19_prepare.
#
# Exercises deferred submission (prepare) against the real cluster scheduler:
#   - prepare several jobs with --group; a prepared job records a "prepared" row
#     but never contacts the scheduler (no .job.id)
#   - `job list --status prepared` surfaces them
#   - `submit next` releases the oldest prepared job first and, restricted by
#     --type/--group, drains one group in prepare order; --wait blocks until the
#     released job completes; a drained group makes `submit next` return non-zero
#   - `prepare from --file` expands a JSON plan (with a matrix: product - exclude
#     + include) into several prepared rows
#   - `submit prepared --id` releases one specific prepared job
#   - `job cancel` on a still-prepared job removes its row and directory without
#     ever contacting the scheduler
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/19_prepare/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/19-prepare-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/19_prepare/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-19"
SQLITE="${WORKDIR}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQLITE}"

DB="${WORKDIR}/.knit/knit.db"

# @fn state_of()
# The recorded lifecycle state of one job id (empty when the row is gone).
state_of() {
    "${SQLITE}" "${DB}" "SELECT state FROM jobs WHERE id='$1';"
}

# @fn group_of()
# The recorded group of one job id ("group" is a SQL keyword, so it is quoted).
group_of() {
    "${SQLITE}" "${DB}" "SELECT \"group\" FROM jobs WHERE id='$1';"
}

# @fn prepared_count()
# Number of jobs in state "prepared", optionally within one group.
prepared_count() {
    local where="state='prepared'"
    [[ -n "${1:-}" ]] && where="${where} AND \"group\"='$1'"
    "${SQLITE}" "${DB}" "SELECT count(*) FROM jobs WHERE ${where};"
}

# ==========================================================================
# Part A — prepare records rows without dispatching; drain a group in order.
# ==========================================================================
id1=$(./experiment.sh prepare --group drain -- sim --n 1 --label one)
id2=$(./experiment.sh prepare --group drain -- sim --n 2 --label two)
id3=$(./experiment.sh prepare --group drain -- sim --n 3 --label three)

check_eq "$(prepared_count drain)" "3" "three jobs prepared in the drain group"
check_eq "$(state_of "${id1}")" "prepared" "a prepared job is in state prepared"

# A prepared job has a job directory but no launcher id: nothing was dispatched.
check_dir "jobs/${id1}" "prepared job has a job directory"
no_dispatch="yes"
[[ -e "jobs/${id1}/.job.id" ]] && no_dispatch="no"
check_eq "${no_dispatch}" "yes" "prepare did not contact the scheduler (no .job.id)"

# `job list --status prepared` surfaces them (json so full ids are not truncated).
./experiment.sh job list --status prepared --types sim --json > prepared.json
check_grep "${id1}" "prepared.json" "job list --status prepared shows the first job"
check_grep "${id2}" "prepared.json" "job list --status prepared shows the second job"
check_grep "${id3}" "prepared.json" "job list --status prepared shows the third job"

# `submit next` releases the oldest first; --type and --group narrow the pick.
r1=$(./experiment.sh submit next --type sim --group drain --wait)
check_eq "${r1}" "${id1}" "submit next releases the oldest prepared job first"
check_eq "$(state_of "${id1}")" "completed" "released job runs to completion under --wait"
check_eq "$(group_of "${id1}")" "drain" "the released job kept its recorded group"

r2=$(./experiment.sh submit next --type sim --group drain --wait)
check_eq "${r2}" "${id2}" "submit next releases the second-oldest job next"
check_eq "$(state_of "${id2}")" "completed" "second released job completed"

r3=$(./experiment.sh submit next --type sim --group drain --wait)
check_eq "${r3}" "${id3}" "submit next releases the last prepared job"
check_eq "$(state_of "${id3}")" "completed" "third released job completed"

check_eq "$(prepared_count drain)" "0" "the drain group is fully drained"

# A drained group makes `submit next` return non-zero, so a queue loop can stop.
set +e
./experiment.sh submit next --type sim --group drain --wait >/dev/null 2>&1
rc=$?
set -e
drained_nonzero="no"
[[ "${rc}" -ne 0 ]] && drained_nonzero="yes"
check_eq "${drained_nonzero}" "yes" "submit next returns non-zero once the group is drained"

# ==========================================================================
# Part B — prepare from a plan with a matrix (product - exclude + include).
# ==========================================================================
cat > plan.json <<'JSON'
{
  "group": "plan",
  "jobs": [
    { "job": "sim", "args": { "n": 5, "label": "baseline" } },

    { "matrix": {
        "job": "sim",
        "axes": {
          "args":  [ {"label": "a"}, {"label": "b"} ],
          "nodes": [ 1, 2 ]
        },
        "exclude": [ { "args": {"label": "b"}, "nodes": 2 } ],
        "include": [ { "args": {"label": "c"}, "nodes": 4 } ]
    } }
  ]
}
JSON

./experiment.sh prepare from --file plan.json
check_eq "$(prepared_count plan)" "5" "prepare from expands the plan to five jobs"

# The matrix is product(2x2) - 1 exclude + 1 include: exactly one nodes=2 (b/2 is
# excluded) and exactly one nodes=4 (the include).
n2=$("${SQLITE}" "${DB}" \
    "SELECT count(*) FROM jobs WHERE state='prepared' AND \"group\"='plan' AND nodes='2';")
n4=$("${SQLITE}" "${DB}" \
    "SELECT count(*) FROM jobs WHERE state='prepared' AND \"group\"='plan' AND nodes='4';")
check_eq "${n2}" "1" "exclude dropped the b/nodes=2 combination"
check_eq "${n4}" "1" "include appended the nodes=4 combination"

# --------------------------------------------------------------------------
# Release one specific prepared job by id (a single-node one, so it schedules).
# --------------------------------------------------------------------------
target=$("${SQLITE}" "${DB}" \
    "SELECT id FROM jobs WHERE state='prepared' AND \"group\"='plan' AND nodes='1' ORDER BY id ASC LIMIT 1;")
./experiment.sh submit prepared --id "${target}" --wait >/dev/null
check_eq "$(state_of "${target}")" "completed" "submit prepared --id released that job"

# --------------------------------------------------------------------------
# Cancel a still-prepared job: its row and directory must be gone, and it must
# never have contacted the scheduler.
# --------------------------------------------------------------------------
doomed=$("${SQLITE}" "${DB}" \
    "SELECT id FROM jobs WHERE state='prepared' AND \"group\"='plan' ORDER BY id ASC LIMIT 1;")
./experiment.sh job cancel --id "${doomed}"
check_eq "$(state_of "${doomed}")" "" "job cancel removed the prepared job's row"
dir_gone="gone"
[[ -e "jobs/${doomed}" ]] && dir_gone="present"
check_eq "${dir_gone}" "gone" "job cancel removed the prepared job's directory"

assert_summary
