#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit

    # Satisfy the bootstrap check
    _KNIT_IS_BOOTSTRAPPED="1"

    # A live FLUX_URI in the host environment would steer detection to Flux; the
    # Flux tests set it explicitly, so start each test with it unset.
    unset FLUX_URI

    # Temporary directory for mock executables
    MOCK_BIN="$(mktemp -d)"
}

teardown() {
    rm -rf "${MOCK_BIN}"
    _KNIT_IS_BOOTSTRAPPED=""
    # Reset detection caches so each test starts clean
    _KNIT_DETECTED_JOB_MANAGER=""
    _KNIT_DETECTED_MPI=""
    _KNIT_DETECTED_LAUNCHER=""
    _KNIT_DETECTED_NODE_NCPUS=""
}

# Helper: write a minimal executable mock script
_write_mock() {
    local path="$1"
    local body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "${body}" > "${path}"
    chmod +x "${path}"
}

# ---------- _knit_detect_job_manager ----------

@test "_knit_detect_job_manager returns slurm when sbatch is in PATH" {
    _write_mock "${MOCK_BIN}/sbatch" "exit 0"
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_job_manager
    [ "$status" -eq 0 ]
    [ "$output" = "slurm" ]
}

@test "_knit_detect_job_manager returns pbs when qsub is in PATH" {
    _write_mock "${MOCK_BIN}/qsub" "exit 0"
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_job_manager
    [ "$status" -eq 0 ]
    [ "$output" = "pbs" ]
}

@test "_knit_detect_job_manager returns <unknown> when neither sbatch nor qsub is in PATH" {
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_job_manager
    [ "$status" -eq 0 ]
    [ "$output" = "<unknown>" ]
}

@test "_knit_detect_job_manager returns slurm when both sbatch and qsub are in PATH" {
    _write_mock "${MOCK_BIN}/sbatch" "exit 0"
    _write_mock "${MOCK_BIN}/qsub"  "exit 0"
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_job_manager
    [ "$status" -eq 0 ]
    [ "$output" = "slurm" ]
}

@test "_knit_detect_job_manager caches its result" {
    _write_mock "${MOCK_BIN}/sbatch" "exit 0"
    # Prime the cache with sbatch present
    PATH="${MOCK_BIN}:${PATH}" _knit_detect_job_manager > /dev/null
    # Remove sbatch — cache should still return "slurm"
    rm "${MOCK_BIN}/sbatch"
    run _knit_detect_job_manager
    [ "$status" -eq 0 ]
    [ "$output" = "slurm" ]
}

@test "_knit_detect_job_manager returns flux when FLUX_URI is set" {
    FLUX_URI="local:///run/flux/local-0" \
        PATH="${MOCK_BIN}:${PATH}" run _knit_detect_job_manager
    [ "$status" -eq 0 ]
    [ "$output" = "flux" ]
}

@test "_knit_detect_job_manager prefers FLUX_URI over sbatch (Flux under Slurm)" {
    # A Flux instance running inside a Slurm allocation: both are reachable, but
    # a live FLUX_URI means Flux owns this shell.
    _write_mock "${MOCK_BIN}/sbatch" "exit 0"
    FLUX_URI="local:///run/flux/local-0" \
        PATH="${MOCK_BIN}:${PATH}" run _knit_detect_job_manager
    [ "$status" -eq 0 ]
    [ "$output" = "flux" ]
}

@test "_knit_detect_job_manager detects Slurm over Flux when FLUX_URI is unset" {
    # flux and sbatch both on PATH but no live instance: the login shell of a
    # Flux-under-Slurm machine correctly detects as Slurm.
    _write_mock "${MOCK_BIN}/sbatch" "exit 0"
    _write_mock "${MOCK_BIN}/flux"   "exit 0"
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_job_manager
    [ "$status" -eq 0 ]
    [ "$output" = "slurm" ]
}

@test "_knit_detect_job_manager returns flux when only flux is in PATH" {
    _write_mock "${MOCK_BIN}/flux" "exit 0"
    PATH="${MOCK_BIN}" run _knit_detect_job_manager
    [ "$status" -eq 0 ]
    [ "$output" = "flux" ]
}

# ---------- _knit_detect_mpi ----------

@test "_knit_detect_mpi returns openmpi when mpirun --version mentions Open MPI" {
    _write_mock "${MOCK_BIN}/mpirun" \
        '[[ "$1" == "--version" ]] && echo "mpirun (Open MPI) 4.1.6" && exit 0; exit 0'
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_mpi
    [ "$status" -eq 0 ]
    [ "$output" = "openmpi" ]
}

@test "_knit_detect_mpi returns mpich when mpirun --version mentions HYDRA" {
    _write_mock "${MOCK_BIN}/mpirun" \
        '[[ "$1" == "--version" ]] && printf "mpirun (Hydra) 4.1.1\nProcess manager: HYDRA\n" && exit 0; exit 0'
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_mpi
    [ "$status" -eq 0 ]
    [ "$output" = "mpich" ]
}

@test "_knit_detect_mpi returns <unknown> when mpirun is not in PATH" {
    # Use a completely isolated PATH so the system mpirun is not visible.
    # _knit_detect_mpi only uses bash builtins (command, echo, printf) so no
    # system binaries are needed.
    PATH="${MOCK_BIN}" run _knit_detect_mpi
    [ "$status" -eq 0 ]
    [ "$output" = "<unknown>" ]
}

@test "_knit_detect_mpi returns <unknown> for an unrecognised mpirun version string" {
    _write_mock "${MOCK_BIN}/mpirun" \
        '[[ "$1" == "--version" ]] && echo "mpirun (Unknown MPI) 1.0" && exit 0; exit 0'
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_mpi
    [ "$status" -eq 0 ]
    [ "$output" = "<unknown>" ]
}

@test "_knit_detect_mpi caches its result" {
    _write_mock "${MOCK_BIN}/mpirun" \
        '[[ "$1" == "--version" ]] && echo "mpirun (Open MPI) 4.1.6" && exit 0; exit 0'
    # Prime the cache with openmpi present
    PATH="${MOCK_BIN}:${PATH}" _knit_detect_mpi > /dev/null
    # Remove mpirun — cache should still return "openmpi"
    rm "${MOCK_BIN}/mpirun"
    run _knit_detect_mpi
    [ "$status" -eq 0 ]
    [ "$output" = "openmpi" ]
}

# ---------- _knit_detect_launcher ----------

@test "_knit_detect_launcher returns pals when mpiexec --help first line mentions Parallel Application Launch Service" {
    _write_mock "${MOCK_BIN}/mpiexec" \
        '[[ "$1" == "--help" ]] && echo "Parallel Application Launch Service 1.2.3" && exit 0; exit 0'
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_launcher
    [ "$status" -eq 0 ]
    [ "$output" = "pals" ]
}

@test "_knit_detect_launcher returns openmpi when mpiexec is not PALS and mpirun is OpenMPI" {
    # mpiexec exists but its first help line is not PALS
    _write_mock "${MOCK_BIN}/mpiexec" \
        '[[ "$1" == "--help" ]] && echo "Usage: mpiexec [options] ..." && exit 0; exit 0'
    _write_mock "${MOCK_BIN}/mpirun" \
        '[[ "$1" == "--version" ]] && echo "mpirun (Open MPI) 4.1.6" && exit 0; exit 0'
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_launcher
    [ "$status" -eq 0 ]
    [ "$output" = "openmpi" ]
}

@test "_knit_detect_launcher returns mpich when mpiexec is not PALS and mpirun is MPICH" {
    _write_mock "${MOCK_BIN}/mpiexec" \
        '[[ "$1" == "--help" ]] && echo "Usage: mpiexec [options] ..." && exit 0; exit 0'
    _write_mock "${MOCK_BIN}/mpirun" \
        '[[ "$1" == "--version" ]] && printf "mpirun (Hydra) 4.1.1\nProcess manager: HYDRA\n" && exit 0; exit 0'
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_launcher
    [ "$status" -eq 0 ]
    [ "$output" = "mpich" ]
}

@test "_knit_detect_launcher returns <unknown> when neither mpiexec nor mpirun is in PATH" {
    # Fully isolated PATH so system mpiexec/mpirun are not visible
    PATH="${MOCK_BIN}" run _knit_detect_launcher
    [ "$status" -eq 0 ]
    [ "$output" = "<unknown>" ]
}

@test "_knit_detect_launcher caches its result" {
    _write_mock "${MOCK_BIN}/mpiexec" \
        '[[ "$1" == "--help" ]] && echo "Parallel Application Launch Service 1.2.3" && exit 0; exit 0'
    # Prime the cache with pals present
    PATH="${MOCK_BIN}:${PATH}" _knit_detect_launcher > /dev/null
    # Remove mpiexec — cache should still return "pals"
    rm "${MOCK_BIN}/mpiexec"
    run _knit_detect_launcher
    [ "$status" -eq 0 ]
    [ "$output" = "pals" ]
}

@test "_knit_detect_launcher returns flux via FLUX_URI when no MPI launcher is present" {
    # No mpiexec/mpirun on an isolated PATH; a live FLUX_URI selects flux.
    FLUX_URI="local:///run/flux/local-0" \
        PATH="${MOCK_BIN}" run _knit_detect_launcher
    [ "$status" -eq 0 ]
    [ "$output" = "flux" ]
}

@test "_knit_detect_launcher returns flux via flux on PATH when no MPI launcher is present" {
    _write_mock "${MOCK_BIN}/flux" "exit 0"
    PATH="${MOCK_BIN}" run _knit_detect_launcher
    [ "$status" -eq 0 ]
    [ "$output" = "flux" ]
}

@test "_knit_detect_launcher prefers an MPI-native launcher over flux" {
    # OpenMPI mpirun and flux both present: the MPI-native launcher wins.
    _write_mock "${MOCK_BIN}/mpirun" \
        '[[ "$1" == "--version" ]] && echo "mpirun (Open MPI) 4.1.6" && exit 0; exit 0'
    _write_mock "${MOCK_BIN}/flux" "exit 0"
    FLUX_URI="local:///run/flux/local-0" \
        PATH="${MOCK_BIN}:${PATH}" run _knit_detect_launcher
    [ "$status" -eq 0 ]
    [ "$output" = "openmpi" ]
}

# ---------- _knit_detect_node_ncpus ----------

@test "_knit_detect_node_ncpus returns the modal slurm cpu count" {
    _write_mock "${MOCK_BIN}/sbatch" "exit 0"
    # sinfo -h -o '%c' prints one CPU count per line; 2 is the modal value.
    _write_mock "${MOCK_BIN}/sinfo" 'printf "2\n2\n4\n"'
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_node_ncpus
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "_knit_detect_node_ncpus ignores a minority outlier (e.g. a login node)" {
    _write_mock "${MOCK_BIN}/sbatch" "exit 0"
    # Node-weighted (-N): three compute nodes at 64, one login node at 256.
    _write_mock "${MOCK_BIN}/sinfo" 'printf "64\n64\n64\n256\n"'
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_node_ncpus
    [ "$status" -eq 0 ]
    [ "$output" = "64" ]
}

@test "_knit_detect_node_ncpus returns the modal pbs cpu count" {
    _write_mock "${MOCK_BIN}/qsub" "exit 0"
    _write_mock "${MOCK_BIN}/pbsnodes" \
        'printf "node1\n    resources_available.ncpus = 8\nnode2\n    resources_available.ncpus = 8\n"'
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_node_ncpus
    [ "$status" -eq 0 ]
    [ "$output" = "8" ]
}

@test "_knit_detect_node_ncpus derives the flux per-node count from cores/nodes" {
    # flux is the job manager (isolated PATH, only flux present). "flux resource
    # list ... {nnodes} {ncores}" reports 2 nodes / 32 cores -> 16 per node.
    # The PATH is fully isolated so an absolute-path shebang is used (as in the
    # getconf test) rather than "env bash".
    printf '#!/bin/bash\n[[ "$1 $2" == "resource list" ]] && printf "2 32\\n" && exit 0\nexit 0\n' \
        > "${MOCK_BIN}/flux"
    chmod +x "${MOCK_BIN}/flux"
    PATH="${MOCK_BIN}" run _knit_detect_node_ncpus
    [ "$status" -eq 0 ]
    [ "$output" = "16" ]
}

@test "_knit_detect_node_ncpus is empty when the flux resource query yields nothing" {
    printf '#!/bin/bash\n[[ "$1 $2" == "resource list" ]] && exit 1\nexit 0\n' \
        > "${MOCK_BIN}/flux"
    chmod +x "${MOCK_BIN}/flux"
    PATH="${MOCK_BIN}" run _knit_detect_node_ncpus
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_knit_detect_node_ncpus falls back to nproc when no scheduler is present" {
    # No sbatch/qsub, so the modal-count branches are skipped; the mock nproc
    # (first in PATH) reports the local core count. The real PATH is kept so the
    # mock's "env bash" shebang can still find an interpreter.
    _write_mock "${MOCK_BIN}/nproc" 'printf "12\n"'
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_node_ncpus
    [ "$status" -eq 0 ]
    [ "$output" = "12" ]
}

@test "_knit_detect_node_ncpus falls back to getconf when nproc is absent" {
    # No scheduler and no nproc: getconf _NPROCESSORS_ONLN is the last resort.
    # PATH is fully isolated so the real nproc is not visible; the mock therefore
    # uses an absolute-path shebang rather than "env bash".
    printf '#!/bin/bash\nprintf "6\\n"\n' > "${MOCK_BIN}/getconf"
    chmod +x "${MOCK_BIN}/getconf"
    PATH="${MOCK_BIN}" run _knit_detect_node_ncpus
    [ "$status" -eq 0 ]
    [ "$output" = "6" ]
}

@test "_knit_detect_node_ncpus is empty when no scheduler and no cpu-count tool" {
    # Fully isolated PATH so neither nproc nor getconf is visible.
    PATH="${MOCK_BIN}" run _knit_detect_node_ncpus
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_knit_detect_node_ncpus is empty when the scheduler query yields nothing" {
    _write_mock "${MOCK_BIN}/sbatch" "exit 0"
    _write_mock "${MOCK_BIN}/sinfo" "exit 1"
    PATH="${MOCK_BIN}:${PATH}" run _knit_detect_node_ncpus
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_knit_detect_node_ncpus caches its result" {
    _write_mock "${MOCK_BIN}/sbatch" "exit 0"
    _write_mock "${MOCK_BIN}/sinfo" 'printf "16\n"'
    PATH="${MOCK_BIN}:${PATH}" _knit_detect_node_ncpus > /dev/null
    # Remove sinfo — cache should still return 16.
    rm "${MOCK_BIN}/sinfo"
    run _knit_detect_node_ncpus
    [ "$status" -eq 0 ]
    [ "$output" = "16" ]
}

# ---------- _knit_detect_sqlite_dev ----------

@test "detect sqlite dev returns 1 when no C compiler is available" {
    export CC="${MOCK_BIN}/no-such-compiler"
    run _knit_detect_sqlite_dev
    [ "$status" -eq 1 ]
}

@test "detect sqlite dev returns 0 when the probe compiles and links" {
    _write_mock "${MOCK_BIN}/mockcc" 'exit 0'
    export CC="${MOCK_BIN}/mockcc"
    run _knit_detect_sqlite_dev
    [ "$status" -eq 0 ]
}

@test "detect sqlite dev returns 1 when the probe fails to build" {
    _write_mock "${MOCK_BIN}/mockcc" 'exit 1'
    export CC="${MOCK_BIN}/mockcc"
    run _knit_detect_sqlite_dev
    [ "$status" -eq 1 ]
}
