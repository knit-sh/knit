#!/usr/bin/env bash
# Integration test 36_pilot_job.
#
# Verifies pilot jobs (knit_with_pilot) against a real scheduler:
#
#   Part A — pack, run concurrently, and record.
#     submit --nodes 2 --wait -- campaign --count 4 --sleep 3 runs the pilot on
#     two compute nodes; its body fires 4 "worker" sub-jobs (--nodes 1 each)
#     through the in-allocation daemon and waits for them with knit job wait. The
#     driver asserts:
#       * all 4 worker jobs reached "completed";
#       * each worker is linked to the pilot by a provenance "call" edge (the
#         campaign body -> submit:worker), i.e. a campaign is a normal
#         parent/child job graph;
#       * two workers ran at the same time (overlapping [start,end] epochs,
#         recorded on the single launch-node clock) — real concurrency, not a
#         serial queue;
#       * the daemon spread the sub-jobs across both allocated nodes (the
#         assigned node subsets, read by each worker from KNIT_PILOT_HOSTFILE,
#         cover both compute nodes).
#
#   Part B — kill propagation.
#     A second pilot fires two long-sleeping workers and is cancelled from the
#     login node while they run. The driver asserts the pilot and both of its
#     sub-jobs end "killed" — a killed pilot never leaves a sub-job running.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/36_pilot_job/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/36-pilot-job-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/36_pilot_job/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap (provisions knit-pilotd, like the other bundled tools)
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-36"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"
check_exec "${WORKDIR}/.knit/knit-pilotd/bin/knit-pilotd" \
    "bootstrap provisioned the knit-pilotd daemon"

DB=".knit/knit.db"

# --------------------------------------------------------------------------
# Detect the scheduler so node assertions match the backend knit auto-detects.
# --------------------------------------------------------------------------
if command -v sbatch >/dev/null 2>&1; then
    NODE_PREFIX="slurm-compute"
elif command -v qsub >/dev/null 2>&1; then
    NODE_PREFIX="pbs-compute"
else
    fail "no supported scheduler (sbatch/qsub) found on the login node"
fi

# --------------------------------------------------------------------------
# Provenance walk: the UUIDs of a pilot's sub-jobs. Two hops from the pilot's
# submission UUID, mirroring the run/app walk in 09_run_app:
#   1. "submit -> submit:campaign": the compute-side pilot body's call edge,
#      whose target is the body's own row id (source is the submission UUID).
#   2. "submit:campaign -> submit": each `knit submit` the body issues records a
#      call edge from the body to the sub-job's submission row; that row lives in
#      the "jobs" table, so the edge target is named for the table's owning
#      command ("submit"), and its target_id is the sub-job's UUID (== jobs.id).
#      (A further "submit -> submit:worker" hop is each sub-job's own body; we
#      want the jobs.id, so we stop at the first hop.) The body's `knit job wait`
#      records a "submit:campaign -> job:wait" edge, excluded by target_name.
# Prints the worker UUIDs, one per line (empty if the body has not run yet).
# --------------------------------------------------------------------------
subjob_uuids_for_pilot() {
    local pilot_uuid="$1" body_id
    body_id=$(${__ASSERT_SQLITE3} "${DB}" \
        "SELECT target_id FROM __provenance__
         WHERE source_id='${pilot_uuid}' AND target_name='submit:campaign'
           AND edge_type='call';")
    [[ -n "${body_id}" ]] || return 0
    ${__ASSERT_SQLITE3} "${DB}" \
        "SELECT target_id FROM __provenance__
         WHERE source_id='${body_id}' AND source_name='submit:campaign'
           AND target_name='submit' AND edge_type='call';"
}

job_state() {
    ${__ASSERT_SQLITE3} "${DB}" "SELECT state FROM jobs WHERE id='$1';"
}

worker_field() {
    local file="$1" field="$2"
    sed -n 's/.*\b'"${field}"'=\([^ ]*\).*/\1/p' "${file}"
}

# Wait (bounded) until the worker's stdout holds its WORKER line.
wait_for_worker_line() {
    local file="$1" _
    for _ in $(seq 1 30); do
        [[ -f "${file}" ]] && grep -q '^WORKER ' "${file}" && return 0
        sleep 1
    done
    return 1
}

# ==========================================================================
# Part A: pack, run concurrently, record.
# ==========================================================================
camp_uuid=$(./experiment.sh submit --nodes 2 --wait -- campaign --count 4 --sleep 3)

check_dir "${WORKDIR}/jobs/${camp_uuid}" "pilot job directory created"
check_sqlite "${DB}" \
    "SELECT state FROM jobs WHERE id='${camp_uuid}';" \
    "completed" \
    "pilot job advanced to completed after --wait"

mapfile -t workers < <(subjob_uuids_for_pilot "${camp_uuid}")
check_eq "${#workers[@]}" "4" "the pilot submitted 4 worker sub-jobs"

# Each worker completed and carries a provenance call edge from the pilot body.
body_id=$(${__ASSERT_SQLITE3} "${DB}" \
    "SELECT target_id FROM __provenance__
     WHERE source_id='${camp_uuid}' AND target_name='submit:campaign'
       AND edge_type='call';")
check_sqlite "${DB}" \
    "SELECT COUNT(*) FROM __provenance__
     WHERE source_id='${body_id}' AND source_name='submit:campaign'
       AND target_name='submit' AND edge_type='call';" \
    "4" \
    "4 'campaign -> submit' call edges recorded (one per sub-job in the jobs table)"

starts=(); ends=(); assigned_all=()
for w in "${workers[@]}"; do
    check_eq "$(job_state "${w}")" "completed" "worker ${w:0:8} completed"
    wfile="${WORKDIR}/jobs/${w}/.stdout"
    wait_for_worker_line "${wfile}" || fail "worker ${w:0:8} wrote no WORKER line"
    starts+=("$(worker_field "${wfile}" start)")
    ends+=("$(worker_field "${wfile}" end)")
    # assigned may be a comma-list; split into the overall node set.
    IFS=',' read -r -a a <<< "$(worker_field "${wfile}" assigned)"
    assigned_all+=("${a[@]}")
done

# Concurrency: some pair of workers overlapped in time (same launch-node clock).
overlap=0
n=${#starts[@]}
for (( i = 0; i < n; i++ )); do
    for (( j = i + 1; j < n; j++ )); do
        if (( starts[i] < ends[j] && starts[j] < ends[i] )); then
            overlap=1
        fi
    done
done
check_eq "${overlap}" "1" "at least two workers ran concurrently (overlapping intervals)"

# Distribution: the daemon placed sub-jobs across both allocated compute nodes.
distinct=$(printf '%s\n' "${assigned_all[@]}" | sed 's/\..*//' | sort -u \
    | grep -c . || true)
check_eq "${distinct}" "2" "sub-jobs packed across both allocated nodes"
for h in $(printf '%s\n' "${assigned_all[@]}" | sed 's/\..*//' | sort -u); do
    case "${h}" in
        "${NODE_PREFIX}"*) ;;
        *) fail "assigned node \"${h}\" is not a ${NODE_PREFIX} node" ;;
    esac
done

# ==========================================================================
# Part B: kill propagation. Cancel a pilot while its sub-jobs run; the whole
# sub-tree must end "killed".
# ==========================================================================
kill_uuid=$(./experiment.sh submit --nodes 2 -- campaign --count 2 --sleep 120)

# Find the sub-jobs while the pilot is still running. The two-hop provenance walk
# used in Part A only resolves once the pilot body *completes* (its own
# "submit -> submit:campaign" edge is recorded post-invocation), but here the body
# is deliberately still blocked in `knit job wait`. The pilot writes each sub-job
# UUID to a tracking file in its job directory as it submits them, so read that —
# it is populated eagerly, while the body runs.
subjobs_file="${WORKDIR}/jobs/${kill_uuid}/.pilot.subjobs"
kworkers=()
for _ in $(seq 1 60); do
    if [[ -r "${subjobs_file}" ]]; then
        mapfile -t kworkers < "${subjobs_file}"
        [[ "${#kworkers[@]}" -eq 2 ]] && break
    fi
    sleep 2
done
check_eq "${#kworkers[@]}" "2" "the second pilot submitted 2 worker sub-jobs"

# Wait until at least one sub-job is actually running under the daemon, so the
# cancel exercises the running-sub-job kill path (not only the queued one).
for _ in $(seq 1 30); do
    running=0
    for w in "${kworkers[@]}"; do
        [[ "$(job_state "${w}")" == "running" ]] && running=1
    done
    [[ "${running}" -eq 1 ]] && break
    sleep 2
done
./experiment.sh job cancel --id "${kill_uuid}"

# The pilot's kill-trap tears the daemon down (kills running sub-jobs, drops
# queued ones) and records the pilot killed. Poll for the terminal states.
wait_killed() {
    local id="$1" _ st
    for _ in $(seq 1 60); do
        st=$(job_state "${id}")
        [[ "${st}" == "killed" ]] && return 0
        # A sub-job may briefly show completed if it raced to the end; only
        # "completed" is an acceptable alternative terminal state to tolerate.
        [[ "${st}" == "completed" ]] && return 0
        sleep 2
    done
    return 1
}

wait_killed "${kill_uuid}" || fail "cancelled pilot did not reach a terminal state"
check_eq "$(job_state "${kill_uuid}")" "killed" "cancelled pilot recorded killed"

for w in "${kworkers[@]}"; do
    wait_killed "${w}" || fail "sub-job ${w:0:8} did not reach a terminal state"
    check_eq "$(job_state "${w}")" "killed" \
        "sub-job ${w:0:8} recorded killed when the pilot was cancelled"
done

assert_summary
