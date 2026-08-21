#!/usr/bin/env bash
# Knit profile validation harness.
#
# A self-contained knit experiment that proves a freshly written machine profile
# actually works end to end -- not just that it parses. It:
#
#   1. builds a tiny MPI-in-C program (mpi_hello.c) with the profile's MPI
#      compiler (mpicc, on PATH via the profile's modules) -- proving the build
#      toolchain the profile selects is real;
#   2. is submitted as a 2-node job through the profile's scheduler -- proving
#      `submit` reaches the batch system and an allocation is granted;
#   3. launches the program as a knit app with `knit run --procs N
#      --procs-per-node P` -- proving the launcher is wired correctly;
#   4. leaves the per-rank output in jobs/<uuid>/.stdout for check.sh to verify
#      rank placement.
#
# This mirrors knit's own `09_run_app` integration test, reduced to one bundled
# experiment. Drive it (after writing the profile) with, e.g.:
#
#   cp /path/to/your/project/knit.sh .        # knit.sh must sit beside this file
#   ./experiment.sh bootstrap --project profile-validation
#   ./experiment.sh setup --name build -- build
#   uuid=$(./experiment.sh submit --setup build --nodes 2 --wait \
#            -- validate --procs 4 --procs-per-node 2)
#   bash check.sh "${uuid}" 4 2
#
# See README.md for the full walkthrough.

# Resolve this script's directory (where mpi_hello.c and check.sh live) before
# sourcing knit.sh, since a setup body runs with its own directory as the cwd.
_VALIDATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locate knit.sh: prefer one beside this harness, else the current directory.
if [[ -f "${_VALIDATE_DIR}/knit.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_VALIDATE_DIR}/knit.sh"
elif [[ -f "./knit.sh" ]]; then
    # shellcheck source=/dev/null
    source "./knit.sh"
else
    echo "knit.sh not found beside this harness or in the current directory." >&2
    echo "Copy your project's knit.sh next to this experiment.sh and retry." >&2
    exit 1
fi

knit_set_program_description \
    "Knit profile validation: build an MPI program, submit a 2-node job, launch it, and check rank placement."

# -----------------------------------------------------------------------------
# Setup "build": compile mpi_hello.c with the profile's MPI compiler.
#
# The setup body runs with KNIT_SETUP_PREFIX as its output directory. It builds
# the binary into <prefix>/bin and puts that on PATH, captured into .activate.sh
# so the job (and every launched rank) inherits it.
# -----------------------------------------------------------------------------
knit_register_setup "build" _build_setup \
    "Compile mpi_hello.c with the profile's MPI compiler (mpicc)."
_build_setup() {
    local src="${_VALIDATE_DIR}/mpi_hello.c"
    if [[ ! -f "${src}" ]]; then
        knit_fatal "%s" "MPI source ${src} not found beside the harness."
    fi
    mkdir -p "${KNIT_SETUP_PREFIX}/bin"
    # mpicc comes from the profile's modules; if the profile is wrong this fails
    # here, which is the point of the validation.
    mpicc "${src}" -o "${KNIT_SETUP_PREFIX}/bin/mpi_hello"
    export PATH="${KNIT_SETUP_PREFIX}/bin:${PATH}"
}
knit_done

# -----------------------------------------------------------------------------
# App "hello": one MPI rank of the hello-world binary.
#
# Like any knit app, `knit run` launches one copy (rank) per MPI process of the
# surrounding job's allocation. This app calls the real MPI binary as a child (no
# exec): the child inherits this rank's PMI environment and joins the same
# size-N world, so mpi_hello reports the rank the launcher assigned. Only rank 0
# records the observed world size.
# -----------------------------------------------------------------------------
knit_register_app "hello" _hello_app "Run one MPI rank of the hello-world binary."
knit_with_output "size:integer" "0" "World size observed by rank 0."
_hello_app() {
    # mpi_hello is on PATH via the build setup's .activate.sh, forwarded to
    # every rank by the launcher. It prints "RANK=.. SIZE=.. HOST=..".
    mpi_hello
    if [[ "${KNIT_MPI_RANK:-0}" == 0 ]]; then
        knit_output "size" "${KNIT_MPI_SIZE}"
    fi
}
knit_done

# -----------------------------------------------------------------------------
# Job "validate": submitted to the scheduler; its body launches the hello app
# across the allocation with `knit run` (the submit -> run nesting).
# -----------------------------------------------------------------------------
knit_register_job "validate" _validate_job "Launch the hello app across the allocation."
knit_with_setup "build"
knit_with_optional "procs:integer" "4" "Total ranks to launch."
knit_with_optional "procs-per-node:integer" "2" "Ranks per node."
knit_with_optional "launcher:string" "" \
    "Launcher backend to use (empty = auto-detect the MPI-native one)."
_validate_job() {
    local procs ppn launcher
    procs=$(knit_get_parameter "procs" "$@")
    ppn=$(knit_get_parameter "procs-per-node" "$@")
    launcher=$(knit_get_parameter "launcher" "$@")
    knit run --procs "${procs}" --procs-per-node "${ppn}" \
        --launcher "${launcher}" -- hello
}
knit_done

knit "$@"
