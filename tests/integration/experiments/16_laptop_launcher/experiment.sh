#!/usr/bin/env bash
# Integration test experiment 16_laptop_launcher.
#
# Exercises the "laptop" launcher path: a machine that declares it offers no
# integrated launcher (bootstrap --launcher none, and no profile at all), where a
# setup supplies the launcher instead via knit_provides_launcher.
#
# With __launcher__ = none the launcher precedence skips the machine tier and
# falls through to a setup's frozen KNIT_PROVIDED_LAUNCHER contract. The setup
# "lmpi" module-loads a real MPI in its body (the non-system MPI baked into each
# cluster image behind an Lmod module, named by ${LAPTOP_MPI_MODULE}); its
# knit_provides_launcher after-callback detects that MPI on the now-active PATH
# and freezes it as KNIT_PROVIDED_LAUNCHER in .activate.sh. The generic setup
# after-callback additionally dumps the module-modified PATH, so a job sourcing
# .activate.sh gets both the launcher binary and the contract with no profile and
# no module system re-initialization.
#
# Registers:
#   - a setup "lmpi" that loads an MPI module and declares knit_provides_launcher.
#     The module to load is named by the LAPTOP_MPI_MODULE environment variable so
#     the same experiment works on both cluster images (mpich on Slurm, openmpi on
#     PBS). Sourcing the module init here (there is no profile to do it) makes the
#     `module` command available in the setup's shell.
#   - a rank-aware probe app "probe" that reports, per rank, which MPI launched it.
#   - a job "laptop" that requires the lmpi setup and launches the probe app with
#     `knit run --procs 4`, exercising the frozen launcher contract end to end.

source /shared/knit/knit.sh

knit_set_program_description \
    "Laptop launcher-contract (knit_provides_launcher, no profile) integration test."

# --------------------------------------------------------------------------
# Setup that supplies the launcher. Its body loads an MPI module (there is no
# profile, so it initializes the module system itself), which prepends the MPI's
# bin to PATH. knit_provides_launcher then detects and freezes that MPI.
# --------------------------------------------------------------------------
knit_register_setup "lmpi" __lmpi_setup \
    "Module-load an MPI and provide it as a launcher contract."
knit_provides_launcher
__lmpi_setup() {
    # No profile initialized the module system, so do it here, then load the MPI
    # named for this image. Its bin lands on PATH; the generic setup after-cb
    # freezes that PATH and knit_provides_launcher freezes the detected launcher.
    # shellcheck disable=SC1091 # image-provided module init
    source /etc/profile.d/modules.sh
    module load "${LAPTOP_MPI_MODULE}"
}
knit_done

# --------------------------------------------------------------------------
# Rank-aware probe app: reports which MPI launched it (mirrors experiment 13).
# --------------------------------------------------------------------------
knit_register_app "probe" __probe_app_fn \
    "Report each rank's MPI flavor and launcher path."
knit_with_output "size:integer" "0" "World size observed by rank 0."
knit_with_output "flavor:string" "" "KNIT_MPI_FLAVOR observed by rank 0 (empty = system MPI)."
__probe_app_fn() {
    local mpiexec_path
    mpiexec_path="$(command -v mpiexec 2>/dev/null \
        || command -v mpirun 2>/dev/null || printf '<none>')"
    printf 'RANK=%s SIZE=%s FLAVOR=%s MPIEXEC=%s HOST=%s\n' \
        "${KNIT_MPI_RANK}" "${KNIT_MPI_SIZE}" "${KNIT_MPI_FLAVOR:-<none>}" \
        "${mpiexec_path}" "$(hostname)"
    knit_output "size" "${KNIT_MPI_SIZE}"
    knit_output "flavor" "${KNIT_MPI_FLAVOR:-<none>}"
}
knit_done

# --------------------------------------------------------------------------
# Job that launches the probe app through the lmpi setup's launcher contract.
# With __launcher__ = none, `knit run` resolves the launcher from the setup's
# frozen KNIT_PROVIDED_LAUNCHER.
# --------------------------------------------------------------------------
knit_register_job "laptop" __laptop_job_fn \
    "Launch the probe app via a setup-provided launcher (no machine launcher)."
knit_with_setup "lmpi"
__laptop_job_fn() {
    knit run --procs 4 --procs-per-node 2 -- probe
}
knit_done

knit "$@"
