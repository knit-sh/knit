#!/usr/bin/env bash
# Integration test 09_run_app.
#
# Verifies `knit run` (the app / launcher layer) against a real scheduler and a
# real MPI launcher (OpenMPI on Slurm, MPICH on PBS):
#
#   - submit --nodes 2 --wait runs the "launch" job on two compute nodes; its
#     body calls `knit run --procs 4 --procs-per-node 2 -- ranks` (submit -> run
#     nesting), so the launcher spreads 4 ranks, 2 per node, across both nodes.
#   - the "ranks" app prints one "RANK=.. SIZE=.. LOCAL=.. HOST=.. MARKER=.."
#     line per rank, captured to <jobdir>/.stdout. The driver asserts:
#       * exactly 4 rank lines, with KNIT_MPI_RANK distinct and covering [0,4)
#       * every rank saw KNIT_MPI_SIZE == 4
#       * the ranks landed on both allocated compute nodes (2 per node) — real
#         multi-node placement, so remote ranks are genuinely exercised
#       * every rank (including the remote ones) saw the forwarded setup marker
#         RUN_APP_MARKER=forwarded-ok — the live confirmation that the launcher
#         forwards the job's environment to remote nodes (no OpenMPI -x needed)
#   - the run is recorded once in the "runs" table (resolved procs / ppn /
#     hostnames, and the parent job UUID), and rank 0's per-app row is recorded
#     exactly once in the "ranks" table, sharing the run UUID (the two join).
#   - a second job "subset" restricts a run to a single allocated host via
#     --hostnames; the driver asserts both its ranks ran on that one host.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/09_run_app/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/09-run-app-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/09_run_app/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap + setup
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-09"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

./experiment.sh setup --path "${WORKDIR}/env" -- env
check_file "env/.activate.sh" "setup produced .activate.sh"

# --------------------------------------------------------------------------
# Detect the scheduler so assertions match the backend knit auto-detects.
# --------------------------------------------------------------------------
if command -v sbatch >/dev/null 2>&1; then
    NODE_PREFIX="slurm-compute"
elif command -v qsub >/dev/null 2>&1; then
    NODE_PREFIX="pbs-compute"
else
    fail "no supported scheduler (sbatch/qsub) found on the login node"
fi

# --------------------------------------------------------------------------
# Extract the "RANK=.. SIZE=.. LOCAL=.. HOST=.. MARKER=.." field from every
# rank line of a job's stdout. Prints one value per rank, in file order.
# --------------------------------------------------------------------------
rank_field() {
    local file="$1" field="$2"
    sed -n 's/.*\b'"${field}"'=\([^ ]*\).*/\1/p' "${file}"
}

# Wait for a --wait job's stdout to be fully flushed (all rank lines written).
wait_for_ranks() {
    local file="$1" want="$2"
    local _ n
    for _ in $(seq 1 30); do
        # grep -c prints the count and exits non-zero on no match, so capture
        # its output and neutralise the exit status rather than appending to it.
        if [[ -f "${file}" ]]; then
            n=$(grep -c '^RANK=' "${file}" 2>/dev/null || true)
        else
            n=0
        fi
        [[ "${n:-0}" -ge "${want}" ]] && break
        sleep 1
    done
}

# --------------------------------------------------------------------------
# Assert a run's stdout shows <want> ranks, distinct and covering [0,want),
# all agreeing that KNIT_MPI_SIZE == want, spread over <nodes> distinct
# NODE_PREFIX hosts, and each carrying the forwarded setup marker. <label>
# tags the assertion messages so native and integrated runs are told apart.
# --------------------------------------------------------------------------
check_ranks_layout() {
    local file="$1" want="$2" nodes="$3" label="$4"

    wait_for_ranks "${file}" "${want}"
    check_file "${file}" "${label}: stdout captured"

    local -a rk sz ho mk
    mapfile -t rk < <(rank_field "${file}" RANK | sort -n)
    check_eq "${#rk[@]}" "${want}" "${label}: produced ${want} rank lines"
    local seq_expected
    seq_expected=$(seq 0 $((want - 1)) | tr '\n' ' ' | sed 's/ $//')
    check_eq "$(printf '%s\n' "${rk[@]}" | tr '\n' ' ' | sed 's/ $//')" \
        "${seq_expected}" "${label}: ranks distinct and cover [0,${want})"

    mapfile -t sz < <(rank_field "${file}" SIZE | sort -u)
    check_eq "${#sz[@]}" "1" "${label}: all ranks agree on KNIT_MPI_SIZE"
    check_eq "${sz[0]}" "${want}" "${label}: KNIT_MPI_SIZE is ${want} on every rank"

    mapfile -t ho < <(rank_field "${file}" HOST | sort -u)
    check_eq "${#ho[@]}" "${nodes}" "${label}: ranks spread across ${nodes} node(s)"
    local h
    for h in "${ho[@]}"; do
        case "${h}" in
            "${NODE_PREFIX}"*) ;;
            *) fail "${label}: rank host \"${h}\" is not a ${NODE_PREFIX} node" ;;
        esac
    done

    # Environment forwarding: the setup marker reached every rank, including the
    # ranks on remote nodes. This is the live confirmation of the OpenMPI "-x"
    # note (launcher-milestones.md M11): plain launcher forwarding suffices, so
    # no targeted -x fallback is needed.
    mapfile -t mk < <(rank_field "${file}" MARKER | sort -u)
    check_eq "${#mk[@]}" "1" "${label}: all ranks saw one forwarded marker"
    check_eq "${mk[0]}" "forwarded-ok" \
        "${label}: setup marker forwarded to every rank (incl. remote nodes)"
}

# The scheduler-integrated launcher to exercise alongside the auto-detected
# MPI-native one (srun under Slurm, the PBS mpiexec wrapper under PBS).
if command -v sbatch >/dev/null 2>&1; then
    INTEGRATED_LAUNCHER="slurm"
else
    INTEGRATED_LAUNCHER="pbs"
fi

# ==========================================================================
# Job 1: "launch" — 4 ranks, 2 per node, spread across both allocated nodes,
# with the auto-detected MPI-native launcher (OpenMPI / MPICH).
# ==========================================================================
launch_uuid=$(./experiment.sh submit --setup "${WORKDIR}/env" --nodes 2 --wait \
    -- launch --procs 4 --procs-per-node 2)

launch_dir="${WORKDIR}/env/jobs/${launch_uuid}"
check_dir "${launch_dir}" "launch job directory created"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${launch_uuid}';" \
    "completed" \
    "launch job advanced to completed after --wait"

check_ranks_layout "${launch_dir}/.stdout" 4 2 "launch (native)"

# Recompute the rank host set for the recording cross-check below.
mapfile -t launch_hosts < <(rank_field "${launch_dir}/.stdout" HOST | sort -u)

# ---- Recording: one runs row with the resolved placement + parent job ----
run_uuid=$(${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT id FROM runs WHERE job='${launch_uuid}';")
[[ -n "${run_uuid}" ]] || fail "no runs row recorded for the launch job"
__assert_pass "runs row recorded for the launch job"

check_sqlite ".knit/knit.db" \
    "SELECT app, procs, procs_per_node FROM runs WHERE id='${run_uuid}';" \
    "ranks|4|2" \
    "runs row records app + resolved procs/procs-per-node"

# hostnames is the resolved two-node list, comma-joined (order = allocation).
# The recorded names come from the backend host source (PBS's $PBS_NODEFILE
# lists FQDNs, Slurm's scontrol lists short names), while the app's "hostname"
# prints the short form; normalise both to the short name (strip any domain)
# before comparing so the check holds on both clusters.
run_hosts=$(${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT hostnames FROM runs WHERE id='${run_uuid}';")
run_hosts_sorted=$(printf '%s\n' "${run_hosts}" | tr ',' '\n' | sed 's/\..*//' \
    | sort -u | tr '\n' ',' | sed 's/,$//')
expected_hosts=$(printf '%s\n' "${launch_hosts[@]}" | sed 's/\..*//' | sort -u \
    | tr '\n' ',' | sed 's/,$//')
check_eq "${run_hosts_sorted}" "${expected_hosts}" \
    "runs row records the resolved two-node hostname list"

# ---- Recording: rank 0's per-app row exists exactly once, and joins ------
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM ranks WHERE id='${run_uuid}';" \
    "1" \
    "exactly one per-app row recorded (rank-0 gating)"
check_sqlite ".knit/knit.db" \
    "SELECT k.size FROM runs r JOIN ranks k ON r.id=k.id WHERE r.id='${run_uuid}';" \
    "4" \
    "per-app row joins the runs row and records the world size"

# ==========================================================================
# Job 2: "launch --launcher <integrated>" — same placement through the
# scheduler-integrated launcher (srun on Slurm, PBS mpiexec on PBS), to
# confirm the explicit --launcher path works end to end on a live cluster.
# ==========================================================================
integ_uuid=$(./experiment.sh submit --setup "${WORKDIR}/env" --nodes 2 --wait \
    -- launch --launcher "${INTEGRATED_LAUNCHER}" --procs 4 --procs-per-node 2)

integ_dir="${WORKDIR}/env/jobs/${integ_uuid}"
check_dir "${integ_dir}" "integrated-launcher job directory created"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${integ_uuid}';" \
    "completed" \
    "integrated-launcher job advanced to completed after --wait"

check_ranks_layout "${integ_dir}/.stdout" 4 2 \
    "launch (${INTEGRATED_LAUNCHER} integrated)"

# ==========================================================================
# Job 3: "subset" — restrict a 2-rank run to a single allocated host.
# ==========================================================================
subset_uuid=$(./experiment.sh submit --setup "${WORKDIR}/env" --nodes 2 --wait \
    -- subset)

subset_dir="${WORKDIR}/env/jobs/${subset_uuid}"
check_dir "${subset_dir}" "subset job directory created"

wait_for_ranks "${subset_dir}/.stdout" 2
check_file "${subset_dir}/.stdout" "subset job stdout captured"

mapfile -t subset_ranks < <(rank_field "${subset_dir}/.stdout" RANK | sort -n)
check_eq "${#subset_ranks[@]}" "2" "subset produced 2 rank lines"

mapfile -t subset_hosts < <(rank_field "${subset_dir}/.stdout" HOST | sort -u)
check_eq "${#subset_hosts[@]}" "1" "subset placed all ranks on a single host"
case "${subset_hosts[0]}" in
    "${NODE_PREFIX}"*) __assert_pass "subset host is a ${NODE_PREFIX} node" ;;
    *) fail "subset host \"${subset_hosts[0]}\" is not a ${NODE_PREFIX} node" ;;
esac

# The runs row for the subset run records that single host (normalise the
# recorded name to its short form, as above, before comparing).
subset_run_uuid=$(${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT id FROM runs WHERE job='${subset_uuid}';")
subset_db_host=$(${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT hostnames FROM runs WHERE id='${subset_run_uuid}';")
check_eq "$(printf '%s' "${subset_db_host}" | sed 's/\..*//')" \
    "${subset_hosts[0]}" \
    "subset runs row records the single requested host"

assert_summary
