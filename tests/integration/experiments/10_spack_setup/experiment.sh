#!/usr/bin/env bash
# Integration test experiment 10_spack_setup.
#
# Registers:
#   - a Spack-backed setup "zlibenv" declared with knit_with_spack_specs "zlib":
#     knit builds and activates a Spack environment as the setup's first step and
#     captures the concrete spack.yaml/spack.lock as provenance outputs.
#   - a job "zcheck" that requires that setup and, on the compute node, confirms
#     the Spack environment was re-hydrated (SPACK_ENV is set) and that zlib is
#     visible to `knit spack`.
#
# Because a registered setup declares a Spack environment, bootstrap
# auto-provisions the knit-private Spack (the M4 -> M2 wiring) even without an
# explicit --spack.

source /shared/knit/knit.sh

knit_set_program_description "Spack-backed setup integration test experiment."

knit_register_setup "zlibenv" __zlibenv_setup "Build a Spack environment with zlib."
knit_with_spack_specs "zlib"
__zlibenv_setup() {
    # The Spack environment is already built and activated by the time this body
    # runs. Export a marker so the dependent job can confirm inheritance.
    export SPACK_SETUP_MARKER="zlibenv-built"
}
knit_done

knit_register_job "zcheck" __zcheck_job "Confirm the Spack-provided zlib is visible."
knit_with_setup "zlibenv"
__zcheck_job() {
    # The job re-hydrates <setup>/.activate.sh, which re-activates the Spack
    # environment, so SPACK_ENV is set here and zlib is on the environment.
    printf 'marker: %s\n' "${SPACK_SETUP_MARKER:-<unset>}"
    printf 'spack_env: %s\n' "${SPACK_ENV:-<unset>}"
    if knit spack find zlib >/dev/null 2>&1; then
        printf 'zlib: found\n'
    else
        printf 'zlib: missing\n'
    fi
}
knit_done

knit "$@"
