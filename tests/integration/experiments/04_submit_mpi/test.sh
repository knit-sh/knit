#!/usr/bin/env bash
# Integration test 04_submit_mpi.
#
# Proves knit can build and launch a REAL compiled MPI program that performs
# genuine inter-rank communication across compute nodes — the one thing the
# env-var shell app in 09_run_app cannot show (its "ranks" app never calls
# MPI_Init). 09 covers the run/launcher plumbing (placement, recording,
# provenance); this test stays focused on the compile-and-communicate path.
#
#   - Setup "mpienv" compiles mpi_allreduce.c with the cluster's mpicc (OpenMPI
#     on Slurm, MPICH on PBS — the same MPI knit's launcher auto-detects) and
#     exports the resulting binary's absolute path.
#   - App "allreduce" runs that binary once per rank. The binary calls MPI_Init
#     and MPI_Allreduce(SUM) over its own rank id, so a correct, identical global
#     sum on every rank is proof the ranks actually communicated.
#   - Job "launch" is submitted on two nodes and its body calls
#     `knit run --procs 4 --procs-per-node 2 -- allreduce`, so the 4 ranks are
#     spread two per node across both allocated nodes and the collective crosses
#     the node boundary.
#
# The binary prints "RANK=<r> SIZE=<n> SUM=<s> HOST=<h>" per rank; the driver
# asserts 4 distinct ranks over [0,4), world size 4, the correct Allreduce sum
# (0+1+2+3 = 6) on every rank, and placement across both compute nodes.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/04_submit_mpi/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

SRC=/shared/knit/tests/integration/experiments/04_submit_mpi
WORKDIR=$(mktemp -d /shared/runs/04-submit-mpi-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

# The experiment plus the MPI source it compiles; both must land in WORKDIR so
# the setup (which runs from its own setup dir) can locate the source relative to
# the experiment script.
cp "${SRC}/experiment.sh" "${SRC}/mpi_allreduce.c" "${WORKDIR}/"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# Which cluster? The compute-node hostname prefix differs, and it is how we
# confirm the ranks landed on real, distinct compute nodes.
# On Slurm and PBS the system MPI is on PATH, so no profile is needed. The Flux
# image keeps its OpenMPI behind an Lmod module, so bootstrap with the baked
# profile: it loads the openmpi module for the setup build (mpicc) and, on the
# compute node, for the compiled binary's runtime libraries.
BOOTSTRAP_PROFILE=()
if command -v sbatch >/dev/null 2>&1; then
    NODE_PREFIX="slurm-compute"
elif command -v qsub >/dev/null 2>&1; then
    NODE_PREFIX="pbs-compute"
elif command -v flux >/dev/null 2>&1; then
    NODE_PREFIX="flux-compute"
    BOOTSTRAP_PROFILE=(--profile flux)
else
    fail "no supported scheduler (sbatch/qsub/flux) found on the login node"
fi

# --------------------------------------------------------------------------
# Extract one <field> value per rank line, in file order.
# --------------------------------------------------------------------------
rank_field() {
    local file="$1" field="$2"
    sed -n 's/.*\b'"${field}"'=\([^ ]*\).*/\1/p' "${file}"
}

# Wait for a --wait job's stdout to hold all <want> rank lines (flush-lag guard).
wait_for_ranks() {
    local file="$1" want="$2" _ n
    for _ in $(seq 1 30); do
        # grep -c prints the count and exits non-zero on no match, so capture its
        # output and neutralise the exit status rather than letting it abort.
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
# Bootstrap, then compile the MPI program in a setup.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-04" "${BOOTSTRAP_PROFILE[@]}"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

./experiment.sh setup --name mpienv -- mpienv
check_exec "setups/mpienv/bin/mpi_allreduce" \
    "setup compiled the MPI program with the cluster mpicc"

# --------------------------------------------------------------------------
# Submit the MPI job on two nodes: 4 ranks, 2 per node. The body calls
# `knit run --procs 4 --procs-per-node 2 -- allreduce`.
# --------------------------------------------------------------------------
uuid=$(./experiment.sh submit --setup mpienv --nodes 2 --wait -- launch)

jobdir="${WORKDIR}/jobs/${uuid}"
check_dir "${jobdir}" "launch job directory created"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${uuid}';" \
    "completed" \
    "MPI job advanced to completed after --wait"

stdout="${jobdir}/.stdout"
wait_for_ranks "${stdout}" 4
check_file "${stdout}" "job stdout captured"

# Ranks: exactly 4, distinct, covering [0,4).
mapfile -t ranks < <(rank_field "${stdout}" RANK | sort -n)
check_eq "${#ranks[@]}" "4" "produced 4 rank lines"
check_eq "$(printf '%s\n' "${ranks[@]}" | tr '\n' ' ' | sed 's/ $//')" \
    "0 1 2 3" "ranks distinct and cover [0,4)"

# World size: every rank agrees it is 4.
mapfile -t sizes < <(rank_field "${stdout}" SIZE | sort -u)
check_eq "${#sizes[@]}" "1" "all ranks agree on the MPI world size"
check_eq "${sizes[0]}" "4" "MPI world size is 4 on every rank"

# The real communication: MPI_Allreduce(SUM of ranks) == 0+1+2+3 == 6 on every
# rank. A correct, identical sum across all ranks is proof the ranks genuinely
# exchanged data through the cluster MPI (across the node boundary).
mapfile -t sums < <(rank_field "${stdout}" SUM | sort -u)
check_eq "${#sums[@]}" "1" "all ranks obtained the same Allreduce result"
check_eq "${sums[0]}" "6" "Allreduce sum of ranks is 6 (0+1+2+3) on every rank"

# Placement: the 4 ranks are spread across both allocated compute nodes, so the
# collective above really crossed the node boundary. Strip any domain so the
# short/FQDN difference between clusters does not matter.
mapfile -t hosts < <(rank_field "${stdout}" HOST | sed 's/\..*//' | sort -u)
check_eq "${#hosts[@]}" "2" "ranks spread across both allocated nodes"
for h in "${hosts[@]}"; do
    case "${h}" in
        "${NODE_PREFIX}"*) ;;
        *) fail "rank host \"${h}\" is not a ${NODE_PREFIX} node" ;;
    esac
done
__assert_pass "all rank hosts are ${NODE_PREFIX} compute nodes"

assert_summary
