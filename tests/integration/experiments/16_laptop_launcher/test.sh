#!/usr/bin/env bash
# Integration test 16_laptop_launcher.
#
# Proves the "laptop" launcher path on a live scheduler: a machine that declares
# it offers NO integrated launcher (bootstrap --launcher none, no profile at all)
# still launches a real MPI app, because a setup supplies the launcher via
# knit_provides_launcher.
#
#   - bootstrap --launcher none (§8.1) with no --profile freezes __launcher__ =
#     none, so the launcher precedence skips the machine tier.
#   - the "lmpi" setup module-loads the non-system MPI (mpiB: mpich on Slurm,
#     openmpi on PBS, from experiment 12's infra) in its body and declares
#     knit_provides_launcher. Its .activate.sh freezes the module-modified PATH
#     plus `export KNIT_PROVIDED_LAUNCHER=<impl>`.
#   - a job requiring that setup runs `knit run --procs 4`; the launcher resolves
#     from the frozen contract to mpiB, which launches 4 distinct ranks. The probe
#     app confirms the world size, that mpiexec is the module install (not the
#     system MPI), and the forwarded KNIT_MPI_FLAVOR; the runs row records mpiB as
#     the resolved launcher.
#
# The 4 ranks run 2 per node across a 2-node allocation (each compute node has 2
# CPUs), so this needs the scheduler even though the launcher is the laptop-style
# setup contract. No profile is involved at any step.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/16_laptop_launcher/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

# --------------------------------------------------------------------------
# Cluster-specific facts. mpiB is the non-system MPI, exposed through an Lmod
# module named after its implementation and installed under /opt/<impl>.
#   slurm: system = OpenMPI (on PATH); module mpiB = mpich   (/opt/mpich)
#   pbs:   system = MPICH   (on PATH); module mpiB = openmpi (/opt/openmpi)
# --------------------------------------------------------------------------
if command -v sbatch >/dev/null 2>&1; then
    MOD_MPI="mpich";   MOD_PREFIX="/opt/mpich"
elif command -v qsub >/dev/null 2>&1; then
    MOD_MPI="openmpi"; MOD_PREFIX="/opt/openmpi"
elif command -v flux >/dev/null 2>&1; then
    # Not applicable to the Flux cluster: a setup-provided MPI-native launcher
    # (mpiexec/mpirun) cannot span nodes without Flux, because the image ships no
    # sshd. Cross-node launch on this cluster always goes through `flux run`.
    echo "SKIP 16_laptop_launcher: not applicable to the Flux cluster (no standalone MPI-native launcher across nodes)."
    exit 0
else
    fail "no supported scheduler (sbatch/qsub) found on the login node"
fi

WORKDIR=$(mktemp -d /shared/runs/16-laptop-launcher-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/16_laptop_launcher/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Extract a "RANK=.. SIZE=.. FLAVOR=.. MPIEXEC=.. HOST=.." field from every rank
# line of a job's stdout. Prints one value per rank, in file order.
# --------------------------------------------------------------------------
probe_field() {
    local file="$1" field="$2"
    sed -n 's/.*\b'"${field}"'=\([^ ]*\).*/\1/p' "${file}"
}

wait_for_ranks() {
    local file="$1" want="$2" _ n
    for _ in $(seq 1 40); do
        if [[ -f "${file}" ]]; then
            n=$(grep -c '^RANK=' "${file}" 2>/dev/null || true)
        else
            n=0
        fi
        [[ "${n:-0}" -ge "${want}" ]] && break
        sleep 1
    done
}

# Resolve the runs-table UUID for a submitted job by walking the provenance call
# edges: submission -> "submit:<job>" (body id) -> "run" (runs.id).
run_uuid_for_job() {
    local sqlite3="$1" db="$2" job_uuid="$3" job_name="$4" body_id run_id
    body_id=$("${sqlite3}" "${db}" \
        "SELECT target_id FROM __provenance__
         WHERE source_id='${job_uuid}' AND target_name='submit:${job_name}'
           AND edge_type='call';")
    [[ -n "${body_id}" ]] || return 0
    run_id=$("${sqlite3}" "${db}" \
        "SELECT target_id FROM __provenance__
         WHERE source_id='${body_id}' AND target_name='run' AND edge_type='call';")
    printf '%s' "${run_id}"
}

# ==========================================================================
# Bootstrap: no profile, and declare the machine has no integrated launcher.
# ==========================================================================
./experiment.sh bootstrap --project "integration-test-16" --launcher none
SQ="${WORKDIR}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQ}"

check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__launcher__';" \
    "none" \
    "bootstrap --launcher none froze __launcher__ = none (no machine launcher)"

# ==========================================================================
# Build the lmpi setup: it module-loads mpiB and freezes the launcher contract.
# LAPTOP_MPI_MODULE tells the (cluster-agnostic) experiment which module to load.
# ==========================================================================
export LAPTOP_MPI_MODULE="${MOD_MPI}"
./experiment.sh setup --name lmpi -- lmpi

check_file "setups/lmpi/.activate.sh" "lmpi setup produced .activate.sh"
check_grep "export KNIT_PROVIDED_LAUNCHER=${MOD_MPI}" "setups/lmpi/.activate.sh" \
    "setup froze the module MPI (${MOD_MPI}) as the launcher contract"
check_grep "${MOD_PREFIX}/bin" "setups/lmpi/.activate.sh" \
    "setup froze the module-modified PATH (${MOD_PREFIX}/bin) into .activate.sh"

# ==========================================================================
# Submit the job. It requires the lmpi setup; `knit run` resolves the launcher
# from the frozen KNIT_PROVIDED_LAUNCHER contract and launches 4 ranks.
# ==========================================================================
job_uuid=$(./experiment.sh submit --setup lmpi --nodes 2 --wait -- laptop)
jobdir="${WORKDIR}/jobs/${job_uuid}"
check_dir "${jobdir}" "job directory created (lmpi setup)"

wait_for_ranks "${jobdir}/.stdout" 4
check_file "${jobdir}/.stdout" "laptop job stdout captured"

# Four distinct ranks covering [0,4), all agreeing KNIT_MPI_SIZE == 4.
mapfile -t rk < <(probe_field "${jobdir}/.stdout" RANK | sort -n)
check_eq "${#rk[@]}" "4" "produced 4 rank lines via the setup-provided launcher"
check_eq "$(printf '%s\n' "${rk[@]}" | tr '\n' ' ' | sed 's/ $//')" \
    "0 1 2 3" "ranks distinct and cover [0,4)"

mapfile -t sz < <(probe_field "${jobdir}/.stdout" SIZE | sort -u)
check_eq "${#sz[@]}" "1" "all ranks agree on KNIT_MPI_SIZE"
check_eq "${sz[0]}" "4" "KNIT_MPI_SIZE is 4 on every rank"

# The module MPI launched (not the system MPI): mpiexec is under /opt/<impl> and
# the module's flavor variable was forwarded to every rank.
mapfile -t fl < <(probe_field "${jobdir}/.stdout" FLAVOR | sort -u)
check_eq "${#fl[@]}" "1" "all ranks agree on FLAVOR"
check_eq "${fl[0]}" "${MOD_MPI}" \
    "KNIT_MPI_FLAVOR forwarded from the setup-loaded ${MOD_MPI} module"

mapfile -t mp < <(probe_field "${jobdir}/.stdout" MPIEXEC | sort -u)
check_eq "${#mp[@]}" "1" "all ranks agree on MPIEXEC"
mpiexec_path="${mp[0]}"
case "${mpiexec_path}" in
    "${MOD_PREFIX}"/*) __assert_pass "mpiexec \"${mpiexec_path}\" is the module install (${MOD_MPI})" ;;
    *) fail "mpiexec \"${mpiexec_path}\" is not under ${MOD_PREFIX} — the setup contract did not launch mpiB" ;;
esac

# The runs row records the launcher resolved from the frozen contract.
run_uuid=$(run_uuid_for_job "${SQ}" "${WORKDIR}/.knit/knit.db" "${job_uuid}" "laptop")
[[ -n "${run_uuid}" ]] || fail "no 'submit:laptop -> run' provenance edge"
check_sqlite ".knit/knit.db" \
    "SELECT launcher FROM runs WHERE id='${run_uuid}';" \
    "${MOD_MPI}" \
    "runs row records the launcher from the setup contract (${MOD_MPI}), with __launcher__ = none"

assert_summary
