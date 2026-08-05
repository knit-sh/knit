#!/usr/bin/env bash
# Integration test experiment 13_platform_mpi_select.
#
# Proves that the machine profile — not the code — selects which MPI launches an
# app. Each cluster image carries two MPIs: the system one on PATH (mpiA) and a
# second one off PATH behind an Lmod module (mpiB, from experiment 12's infra).
# The same job/app is launched under three different bootstraps:
#
#   - a minimal profile with NO modules and NO launcher.type -> knit falls
#     through to detection and launches under the *system* MPI (mpiA); the app
#     sees no KNIT_MPI_FLAVOR and an mpiexec that is not the module install.
#   - the baked cluster profile (modules + launcher.type) -> knit loads the
#     module and launches under mpiB; the app sees KNIT_MPI_FLAVOR=<impl> and an
#     mpiexec under the module prefix.
#   - a profile whose launcher.type is the scheduler-integrated launcher, used by
#     a job whose setup declares knit_provides_launcher (freezing the *system*
#     MPI as KNIT_PROVIDED_LAUNCHER) -> the profile's launcher still wins, proving
#     the profile beats the setup contract in the precedence.
#
# The "probe" app prints, per rank:
#   RANK=<r> SIZE=<s> FLAVOR=<KNIT_MPI_FLAVOR|<none>> MPIEXEC=<path|<none>> HOST=<h>
# so the driver can confirm the world size, which MPI's launcher is on PATH, and
# whether the module's flavor variable was forwarded.

source knit.sh

knit_set_program_description "knit MPI-selection (profile) integration test experiment."

# --------------------------------------------------------------------------
# A setup that declares it may supply a launcher. Its body builds nothing, so
# knit_provides_launcher detects and freezes whatever MPI is already on PATH at
# setup time (the system MPI). Used only by the "profile beats setup" job.
# --------------------------------------------------------------------------
knit_register_setup "frozen" __frozen_setup_fn "Freeze the system MPI as a launcher contract."
knit_provides_launcher
__frozen_setup_fn() {
    :
}
knit_done

# --------------------------------------------------------------------------
# Rank-aware probe app: reports which MPI launched it.
# --------------------------------------------------------------------------
knit_register_app "probe" __probe_app_fn "Report each rank's MPI flavor and launcher path."
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
# Job that launches the probe app under the profile's launcher. No setup
# directive -> it adopts the builtin "default" setup, whose .activate.sh carries
# the profile's platform activation (the module load, when the profile has one).
# --------------------------------------------------------------------------
knit_register_job "run4" __run4_job_fn "Launch the probe app under the profile launcher."
__run4_job_fn() {
    knit run --procs 4 --procs-per-node 2 -- probe
}
knit_done

# --------------------------------------------------------------------------
# Same launch, but through the "frozen" setup that provides a launcher contract.
# The profile's launcher must still win over KNIT_PROVIDED_LAUNCHER.
# --------------------------------------------------------------------------
knit_register_job "run4frozen" __run4frozen_job_fn "Launch under a profile that beats a setup launcher contract."
knit_with_setup "frozen"
__run4frozen_job_fn() {
    knit run --procs 4 --procs-per-node 2 -- probe
}
knit_done

knit "$@"
