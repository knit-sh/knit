#!/usr/bin/env bash
# Integration test experiment 12_platform_modules.
#
# Registers:
#   - a plain setup "modenv" (no Spack): by the time its body runs, the platform
#     (.knit/platform.sh, materialized at bootstrap from the --profile) has been
#     sourced, so the profile's Lmod modules are already loaded. It exports a
#     marker so a dependent job can confirm the setup ran.
#   - a job "modcheck" that requires that setup and, on the compute node, reports
#     the module-provided variables (KNIT_MODULE_MARKER from knit-marker, and
#     KNIT_MPI_FLAVOR from the non-system MPI module) plus the setup's own marker.
#
# The profile loaded at bootstrap (/etc/knit/profiles/<cluster>.json, baked into
# the image) lists the marker module plus the non-system MPI module (named after
# its implementation — mpich on Slurm, openmpi on PBS), so this exercises the
# knit <-> environment-modules interaction end to end.

source /shared/knit/knit.sh

knit_set_program_description "Platform / environment-modules integration test."

knit_register_setup "modenv" __modenv_setup \
    "A setup that inherits the profile's loaded modules."
__modenv_setup() {
    # The platform activation (module loads) already happened before this body.
    export MODENV_MARKER="modenv-built"
}
knit_done

knit_register_job "modcheck" __modcheck_job \
    "Report the platform module-provided environment."
knit_with_setup "modenv"
__modcheck_job() {
    # Re-hydrating <setup>/.activate.sh re-runs the inlined platform activation,
    # so the profile's modules are loaded here on the compute node.
    printf 'module_marker: %s\n' "${KNIT_MODULE_MARKER:-<unset>}"
    printf 'mpi_flavor: %s\n' "${KNIT_MPI_FLAVOR:-<unset>}"
    printf 'setup_marker: %s\n' "${MODENV_MARKER:-<unset>}"
}
knit_done

knit "$@"
