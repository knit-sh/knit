#!/usr/bin/env bash
# Integration test 13_platform_mpi_select.
#
# Proves the machine profile selects which MPI launches an app, on a live
# scheduler with two real MPIs in the image (system MPI on PATH = mpiA; a second
# MPI off PATH behind an Lmod module = mpiB, from experiment 12's infra):
#
#   Case A (mpiA): bootstrap with a minimal profile that has NO modules and NO
#     launcher.type. knit falls through to detection and launches under the
#     system MPI. The probe app sees no KNIT_MPI_FLAVOR and an mpiexec that is
#     not the module install; the runs row records the system launcher.
#
#   Case B (mpiB): bootstrap --profile <cluster> (the baked profile: module +
#     launcher.type). knit loads the module and launches under it. The probe app
#     sees KNIT_MPI_FLAVOR=<impl> and an mpiexec under the module prefix; the
#     runs row records the module launcher.
#
#   Case C (profile beats setup contract): bootstrap with a profile whose
#     launcher.type is the scheduler-integrated launcher, and run a job whose
#     "frozen" setup declares knit_provides_launcher (freezing the system MPI as
#     KNIT_PROVIDED_LAUNCHER). The profile launcher still wins: the runs row
#     records the profile's launcher, not the frozen contract.
#
# On the Flux cluster mpiA is `flux run` itself: a system MPICH is on PATH only
# as a detection foil, and scheduler-aware detection makes `flux run` win over
# it, so Case A proves flux run beats an on-PATH MPI-native launcher. Case B
# selects the openmpi module (mpirun across nodes). Case C is a real precedence
# discriminator on flux too: the frozen setup detects only MPI-native launchers
# (never flux), so it freezes the on-PATH MPICH foil, while the profile resolves
# to flux — the profile launcher (flux) beating the frozen contract (mpich)
# proves precedence rather than merely riding along.
#
# Every case launches 4 ranks (2 per node across a 2-node allocation), distinct
# and covering [0,4), all agreeing on KNIT_MPI_SIZE == 4.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/13_platform_mpi_select/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

# --------------------------------------------------------------------------
# Cluster-specific facts. The "system MPI" (mpiA) is what auto-detection selects
# when the profile names no launcher; the module MPI (mpiB) is off PATH behind an
# Lmod module and is selected by a profile. They are swapped between clusters.
# FROZEN_MPI is what a setup's knit_provides_launcher freezes on the login node:
# it probes only MPI-native launchers, so on flux it is the on-PATH MPICH foil,
# not the scheduler-aware system launcher (flux). On slurm/pbs the system MPI is
# itself MPI-native, so FROZEN_MPI == SYS_MPI there.
#   slurm: mpiA = OpenMPI (/usr/local, on PATH);  mpiB = mpich  (/opt/mpich)
#   pbs:   mpiA = MPICH  (/usr/lib64, on PATH);    mpiB = openmpi (/opt/openmpi)
#   flux:  mpiA = flux run (auto-detected; a system MPICH is on PATH only as a
#          detection foil);                        mpiB = openmpi (/usr/lib64
#          module). Detection is scheduler-aware: under a Flux scheduler flux run
#          wins even though MPICH is on PATH, so mpiA is "flux", not mpich. But a
#          setup contract is MPI-native only, so FROZEN_MPI = mpich (the foil).
# --------------------------------------------------------------------------
IS_FLUX=""
if command -v sbatch >/dev/null 2>&1; then
    PROFILE="slurm"; SCHED="slurm"
    SYS_MPI="openmpi"; MOD_MPI="mpich";   MOD_PREFIX="/opt/mpich"
    FROZEN_MPI="${SYS_MPI}"
elif command -v qsub >/dev/null 2>&1; then
    PROFILE="pbs"; SCHED="pbs"
    SYS_MPI="mpich";   MOD_MPI="openmpi"; MOD_PREFIX="/opt/openmpi"
    FROZEN_MPI="${SYS_MPI}"
elif command -v flux >/dev/null 2>&1; then
    SCHED="flux"; IS_FLUX=1
    SYS_MPI="flux"; MOD_MPI="openmpi"; MOD_PREFIX="/usr/lib64/openmpi"
    # The setup contract probes MPI-native launchers only, so it freezes the
    # on-PATH MPICH foil, not flux — giving Case C a real precedence check.
    FROZEN_MPI="mpich"
    # PROFILE (Case B) is a custom file written after WORKDIR exists (below): the
    # baked flux profile pins launcher.type=flux, not the module MPI, so it cannot
    # serve as the module-selecting profile.
else
    fail "no supported scheduler (sbatch/qsub/flux) found on the login node"
fi

WORKDIR=$(mktemp -d /shared/runs/13-mpi-select-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

EXP=/shared/knit/tests/integration/experiments/13_platform_mpi_select/experiment.sh

# Minimal profile: no modules, no launcher.type -> system MPI by detection.
cat >"${WORKDIR}/mpiA.json" <<'JSON'
{
    "description": "Minimal profile: no modules and no launcher.type, so knit auto-detects and launches under the system MPI."
}
JSON

# Profile whose launcher.type is the scheduler-integrated launcher. No modules;
# used to prove a profile launcher beats a setup's knit_provides_launcher.
cat >"${WORKDIR}/beats.json" <<JSON
{
    "description": "Profile whose launcher is the scheduler-integrated launcher; used to prove it beats a setup's knit_provides_launcher contract.",
    "launcher": { "type": "${SCHED}" }
}
JSON

# Flux Case B profile: the baked flux profile pins launcher.type=flux, so Case B
# needs its own profile that loads the openmpi module and pins launcher.type=
# openmpi. This launches the app under OpenMPI's mpirun across nodes (the MPI-
# over-SSH path proven by experiment 16), distinct from Case A's auto-detected
# flux run.
if [[ -n "${IS_FLUX}" ]]; then
    cat >"${WORKDIR}/mpiB.json" <<'JSON'
{
    "description": "Flux Case B: load the openmpi module and launch under OpenMPI's mpirun (not flux run).",
    "launcher": { "type": "openmpi" },
    "module_init": "/etc/profile.d/modules.sh",
    "modules": ["knit-marker", "openmpi"]
}
JSON
    PROFILE="${WORKDIR}/mpiB.json"
fi

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

# Assert a probe run produced 4 distinct ranks covering [0,4), all agreeing that
# KNIT_MPI_SIZE == 4. <label> tags the assertion messages.
check_probe_ranks() {
    local file="$1" label="$2"
    wait_for_ranks "${file}" 4
    check_file "${file}" "${label}: stdout captured"

    local -a rk sz
    mapfile -t rk < <(probe_field "${file}" RANK | sort -n)
    check_eq "${#rk[@]}" "4" "${label}: produced 4 rank lines"
    check_eq "$(printf '%s\n' "${rk[@]}" | tr '\n' ' ' | sed 's/ $//')" \
        "0 1 2 3" "${label}: ranks distinct and cover [0,4)"

    mapfile -t sz < <(probe_field "${file}" SIZE | sort -u)
    check_eq "${#sz[@]}" "1" "${label}: all ranks agree on KNIT_MPI_SIZE"
    check_eq "${sz[0]}" "4" "${label}: KNIT_MPI_SIZE is 4 on every rank"
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
# Case A — mpiA: minimal profile -> system MPI by detection.
# ==========================================================================
A="${WORKDIR}/A"; mkdir -p "${A}"; cp "${EXP}" "${A}/experiment.sh"
cp /shared/knit/knit.sh "${A}/knit.sh"   # bare `source knit.sh` needs it beside the script
chmod +x "${A}/experiment.sh"; cd "${A}"

./experiment.sh bootstrap --project "int-13-mpiA" --profile "${WORKDIR}/mpiA.json"
SQA="${A}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQA}"

# No launcher.type in the profile -> __launcher__ is the detected system MPI.
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__launcher__';" \
    "${SYS_MPI}" \
    "mpiA: no-launcher profile detected the system MPI (${SYS_MPI})"

a_uuid=$(./experiment.sh submit --nodes 2 --wait -- run4)
a_dir="${A}/jobs/${a_uuid}"
check_dir "${a_dir}" "mpiA: job directory created (default setup adopted)"
check_probe_ranks "${a_dir}/.stdout" "mpiA"

mapfile -t a_fl < <(probe_field "${a_dir}/.stdout" FLAVOR | sort -u)
check_eq "${#a_fl[@]}" "1" "mpiA: all ranks agree on FLAVOR"
check_eq "${a_fl[0]}" "<none>" \
    "mpiA: no KNIT_MPI_FLAVOR (no module loaded) — system MPI"
mapfile -t a_mp < <(probe_field "${a_dir}/.stdout" MPIEXEC | sort -u)
check_eq "${#a_mp[@]}" "1" "mpiA: all ranks agree on MPIEXEC"
a_mpiexec="${a_mp[0]}"
case "${a_mpiexec}" in
    "${MOD_PREFIX}"/*) fail "mpiA: mpiexec \"${a_mpiexec}\" is the module install, expected the system MPI" ;;
    *) __assert_pass "mpiA: mpiexec \"${a_mpiexec}\" is not the module install (system MPI)" ;;
esac

a_run=$(run_uuid_for_job "${SQA}" "${A}/.knit/knit.db" "${a_uuid}" "run4")
[[ -n "${a_run}" ]] || fail "mpiA: no 'submit:run4 -> run' provenance edge"
check_sqlite ".knit/knit.db" \
    "SELECT launcher FROM runs WHERE id='${a_run}';" \
    "${SYS_MPI}" \
    "mpiA: runs row records the resolved system launcher (${SYS_MPI})"

# ==========================================================================
# Case B — mpiB: baked cluster profile -> module MPI.
# ==========================================================================
B="${WORKDIR}/B"; mkdir -p "${B}"; cp "${EXP}" "${B}/experiment.sh"
cp /shared/knit/knit.sh "${B}/knit.sh"   # bare `source knit.sh` needs it beside the script
chmod +x "${B}/experiment.sh"; cd "${B}"

./experiment.sh bootstrap --project "int-13-mpiB" --profile "${PROFILE}"
SQB="${B}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQB}"

check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__launcher__';" \
    "${MOD_MPI}" \
    "mpiB: profile selected the module launcher (${MOD_MPI})"

b_uuid=$(./experiment.sh submit --nodes 2 --wait -- run4)
b_dir="${B}/jobs/${b_uuid}"
check_dir "${b_dir}" "mpiB: job directory created (default setup adopted)"
check_probe_ranks "${b_dir}/.stdout" "mpiB"

mapfile -t b_fl < <(probe_field "${b_dir}/.stdout" FLAVOR | sort -u)
check_eq "${#b_fl[@]}" "1" "mpiB: all ranks agree on FLAVOR"
check_eq "${b_fl[0]}" "${MOD_MPI}" \
    "mpiB: KNIT_MPI_FLAVOR forwarded from the profile-loaded ${MOD_MPI} module"
mapfile -t b_mp < <(probe_field "${b_dir}/.stdout" MPIEXEC | sort -u)
check_eq "${#b_mp[@]}" "1" "mpiB: all ranks agree on MPIEXEC"
b_mpiexec="${b_mp[0]}"
case "${b_mpiexec}" in
    "${MOD_PREFIX}"/*) __assert_pass "mpiB: mpiexec \"${b_mpiexec}\" is the module install" ;;
    *) fail "mpiB: mpiexec \"${b_mpiexec}\" is not under ${MOD_PREFIX} (module MPI)" ;;
esac

b_run=$(run_uuid_for_job "${SQB}" "${B}/.knit/knit.db" "${b_uuid}" "run4")
[[ -n "${b_run}" ]] || fail "mpiB: no 'submit:run4 -> run' provenance edge"
check_sqlite ".knit/knit.db" \
    "SELECT launcher FROM runs WHERE id='${b_run}';" \
    "${MOD_MPI}" \
    "mpiB: runs row records the resolved module launcher (${MOD_MPI})"

# A and B selected different MPIs from the same code — profile drove the choice.
[[ "${SYS_MPI}" != "${MOD_MPI}" ]] \
    && __assert_pass "profile drives MPI selection: mpiA=${SYS_MPI} vs mpiB=${MOD_MPI}"

# ==========================================================================
# Case C — profile launcher beats a setup's knit_provides_launcher contract.
# ==========================================================================
C="${WORKDIR}/C"; mkdir -p "${C}"; cp "${EXP}" "${C}/experiment.sh"
cp /shared/knit/knit.sh "${C}/knit.sh"   # bare `source knit.sh` needs it beside the script
chmod +x "${C}/experiment.sh"; cd "${C}"

./experiment.sh bootstrap --project "int-13-beats" --profile "${WORKDIR}/beats.json"
SQC="${C}/.knit/sqlite/bin/sqlite3"
export __ASSERT_SQLITE3="${SQC}"

# The profile launcher is the scheduler-integrated one.
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__launcher__';" \
    "${SCHED}" \
    "beats: profile set the scheduler-integrated launcher (${SCHED})"

# Instantiate the "frozen" setup: knit_provides_launcher detects and freezes an
# MPI-native launcher (nothing built, so its PATH is the login node's; the probe
# never returns flux, so on the Flux cluster this is the on-PATH MPICH foil).
./experiment.sh setup --name frozen -- frozen
check_file "setups/frozen/.activate.sh" "beats: frozen setup produced .activate.sh"
check_grep "export KNIT_PROVIDED_LAUNCHER=${FROZEN_MPI}" "setups/frozen/.activate.sh" \
    "beats: setup froze the MPI-native launcher (${FROZEN_MPI}) as the contract"

c_uuid=$(./experiment.sh submit --setup frozen --nodes 2 --wait -- run4frozen)
c_dir="${C}/jobs/${c_uuid}"
check_dir "${c_dir}" "beats: job directory created (frozen setup)"
check_probe_ranks "${c_dir}/.stdout" "beats"

c_run=$(run_uuid_for_job "${SQC}" "${C}/.knit/knit.db" "${c_uuid}" "run4frozen")
[[ -n "${c_run}" ]] || fail "beats: no 'submit:run4frozen -> run' provenance edge"

# The profile's launcher won: the run recorded the profile launcher, NOT the
# MPI-native launcher the setup froze into KNIT_PROVIDED_LAUNCHER.
check_sqlite ".knit/knit.db" \
    "SELECT launcher FROM runs WHERE id='${c_run}';" \
    "${SCHED}" \
    "beats: runs row records the PROFILE launcher (${SCHED}), beating the setup contract (${FROZEN_MPI})"
[[ "${SCHED}" != "${FROZEN_MPI}" ]] \
    && __assert_pass "beats: profile launcher (${SCHED}) differs from the frozen contract (${FROZEN_MPI})"

assert_summary
