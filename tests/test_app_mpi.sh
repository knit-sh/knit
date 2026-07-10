#!/usr/bin/env bats

setup() {
    source knit.sh
    # Start each test from a known-empty MPI environment: clear every
    # launcher-native variable the host environment might carry, plus any
    # KNIT_MPI_* left over from a previous normalization.
    unset OMPI_COMM_WORLD_RANK OMPI_COMM_WORLD_SIZE OMPI_COMM_WORLD_LOCAL_RANK
    unset PMI_RANK PMI_SIZE PMI_LOCAL_RANK
    unset SLURM_PROCID SLURM_NTASKS SLURM_LOCALID
    unset PALS_RANKID PALS_LOCAL_RANKID
    unset KNIT_MPI_RANK KNIT_MPI_SIZE KNIT_MPI_LOCAL_RANK
}

teardown() {
    unset KNIT_JOB_PREFIX
    _KNIT_RECORDING_SUPPRESSED=""
}

# ---------- none backend (no launcher variables) ----------

@test "mpi env: no launcher variables -> rank 0, size 1, local rank 0" {
    _knit_run_normalize_mpi_env
    [ "${KNIT_MPI_RANK}" = "0" ]
    [ "${KNIT_MPI_SIZE}" = "1" ]
    [ "${KNIT_MPI_LOCAL_RANK}" = "0" ]
}

# ---------- per-launcher normalization ----------

@test "mpi env: OpenMPI variables are normalized" {
    export OMPI_COMM_WORLD_RANK=3
    export OMPI_COMM_WORLD_SIZE=8
    export OMPI_COMM_WORLD_LOCAL_RANK=1
    _knit_run_normalize_mpi_env
    [ "${KNIT_MPI_RANK}" = "3" ]
    [ "${KNIT_MPI_SIZE}" = "8" ]
    [ "${KNIT_MPI_LOCAL_RANK}" = "1" ]
}

@test "mpi env: MPICH/PMI variables are normalized" {
    export PMI_RANK=5
    export PMI_SIZE=16
    export PMI_LOCAL_RANK=2
    _knit_run_normalize_mpi_env
    [ "${KNIT_MPI_RANK}" = "5" ]
    [ "${KNIT_MPI_SIZE}" = "16" ]
    [ "${KNIT_MPI_LOCAL_RANK}" = "2" ]
}

@test "mpi env: Slurm srun variables are normalized" {
    export SLURM_PROCID=7
    export SLURM_NTASKS=32
    export SLURM_LOCALID=3
    _knit_run_normalize_mpi_env
    [ "${KNIT_MPI_RANK}" = "7" ]
    [ "${KNIT_MPI_SIZE}" = "32" ]
    [ "${KNIT_MPI_LOCAL_RANK}" = "3" ]
}

@test "mpi env: PALS variables are normalized (size from PMI_SIZE)" {
    export PALS_RANKID=4
    export PMI_SIZE=64
    export PALS_LOCAL_RANKID=1
    _knit_run_normalize_mpi_env
    [ "${KNIT_MPI_RANK}" = "4" ]
    [ "${KNIT_MPI_SIZE}" = "64" ]
    [ "${KNIT_MPI_LOCAL_RANK}" = "1" ]
}

# ---------- precedence ----------

@test "mpi env: OpenMPI takes precedence over PMI and Slurm" {
    export OMPI_COMM_WORLD_RANK=1
    export PMI_RANK=9
    export SLURM_PROCID=9
    export OMPI_COMM_WORLD_SIZE=4
    export PMI_SIZE=9
    export OMPI_COMM_WORLD_LOCAL_RANK=0
    export PMI_LOCAL_RANK=9
    _knit_run_normalize_mpi_env
    [ "${KNIT_MPI_RANK}" = "1" ]
    [ "${KNIT_MPI_SIZE}" = "4" ]
    [ "${KNIT_MPI_LOCAL_RANK}" = "0" ]
}

@test "mpi env: PMI takes precedence over Slurm when OpenMPI is absent" {
    export PMI_RANK=2
    export SLURM_PROCID=9
    export PMI_SIZE=6
    export SLURM_NTASKS=9
    export PMI_LOCAL_RANK=1
    export SLURM_LOCALID=9
    _knit_run_normalize_mpi_env
    [ "${KNIT_MPI_RANK}" = "2" ]
    [ "${KNIT_MPI_SIZE}" = "6" ]
    [ "${KNIT_MPI_LOCAL_RANK}" = "1" ]
}

# ---------- export ----------

@test "mpi env: normalized values are exported to child processes" {
    export OMPI_COMM_WORLD_RANK=2
    export OMPI_COMM_WORLD_SIZE=5
    export OMPI_COMM_WORLD_LOCAL_RANK=1
    _knit_run_normalize_mpi_env
    run bash -c 'printf "%s/%s/%s\n" "${KNIT_MPI_RANK}" "${KNIT_MPI_LOCAL_RANK}" "${KNIT_MPI_SIZE}"'
    [ "$output" = "2/1/5" ]
}

# ---------- worker integration ----------

@test "worker normalizes the MPI env before running the app body" {
    _app_fn() {
        printf '%s/%s/%s\n' \
            "${KNIT_MPI_RANK}" "${KNIT_MPI_LOCAL_RANK}" "${KNIT_MPI_SIZE}" \
            > "${BATS_TEST_TMPDIR}/out"
    }
    knit_register_app "myapp" "_app_fn" "A test app."
    knit_done
    export KNIT_JOB_PREFIX="${BATS_TEST_TMPDIR}/job"
    export OMPI_COMM_WORLD_RANK=6
    export OMPI_COMM_WORLD_SIZE=12
    export OMPI_COMM_WORLD_LOCAL_RANK=2
    _knit_run_worker -- myapp
    [ "$(cat "${BATS_TEST_TMPDIR}/out")" = "6/2/12" ]
}

# ---------- rank-0 recording gating ----------

@test "worker suppresses recording on non-root ranks (output ignored)" {
    _app_fn() { knit_output "result" "42"; }
    knit_register_app "myapp" "_app_fn" "A test app."
    knit_with_output "result:integer" "0" "The result."
    knit_done
    export KNIT_JOB_PREFIX="${BATS_TEST_TMPDIR}/job"
    export OMPI_COMM_WORLD_RANK=1
    export OMPI_COMM_WORLD_SIZE=4
    _knit_run_worker -- myapp
    # Non-root rank: knit_output is a no-op, so nothing was recorded.
    [ -z "${_KNIT_CMD_run__1__myapp_output_value[result]:-}" ]
    [ -n "${_KNIT_RECORDING_SUPPRESSED}" ]
}

@test "worker records on rank 0 (output kept)" {
    _app_fn() { knit_output "result" "42"; }
    knit_register_app "myapp" "_app_fn" "A test app."
    knit_with_output "result:integer" "0" "The result."
    knit_done
    export KNIT_JOB_PREFIX="${BATS_TEST_TMPDIR}/job"
    export OMPI_COMM_WORLD_RANK=0
    export OMPI_COMM_WORLD_SIZE=4
    _knit_run_worker -- myapp
    # Rank 0: recording is not suppressed, so the output is kept.
    [ "${_KNIT_CMD_run__1__myapp_output_value[result]}" = "42" ]
    [ -z "${_KNIT_RECORDING_SUPPRESSED}" ]
}

# ---------- direct-invocation guard ----------

@test "app before-callback fatals when invoked outside a job" {
    unset KNIT_JOB_PREFIX
    run _knit_app_before_cb
    [ "$status" -ne 0 ]
    [[ "$output" == *"knit run"* ]]
}
