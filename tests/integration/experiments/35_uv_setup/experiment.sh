#!/usr/bin/env bash
# Integration test experiment 35_uv_setup.
#
# Registers:
#   - a uv-backed setup "pyenv" declared with knit_with_uv_specs "six": knit
#     builds and activates a uv Python environment as the setup's first step and
#     captures the concrete pyproject.toml/uv.lock as provenance outputs.
#   - a job "pycheck" that requires that setup and, on the compute node, confirms
#     the uv environment was re-hydrated (VIRTUAL_ENV is set) and that the
#     six package is importable.
#
# Because a registered setup declares a uv environment, bootstrap auto-provisions
# the knit-private uv (the env-manager required-flag wiring) even without an
# explicit --uv.

source knit.sh

# uv is a plugin; import it for the uv environment manager and "knit uv".
knit_import uv@v1.0.0

knit_set_program_description "uv-backed setup integration test experiment."

knit_register_setup "pyenv" __pyenv_setup "Build a uv Python environment with six."
knit_with_uv_specs "six"
__pyenv_setup() {
    # The uv environment is already built and activated by the time this body
    # runs. Declare a marker so the dependent job can confirm inheritance.
    knit_setup_env_set UV_SETUP_MARKER "pyenv-built"
}
knit_done

knit_register_job "pycheck" __pycheck_job "Confirm the uv-provided six is importable."
knit_with_setup "pyenv"
__pycheck_job() {
    # The job re-hydrates <setup>/.activate.sh, which re-activates the uv venv,
    # so VIRTUAL_ENV is set here and six is importable by the venv's python.
    printf 'marker: %s\n' "${UV_SETUP_MARKER:-<unset>}"
    printf 'venv: %s\n' "${VIRTUAL_ENV:-<unset>}"
    if python -c 'import six' >/dev/null 2>&1; then
        printf 'six: found\n'
    else
        printf 'six: missing\n'
    fi
}
knit_done

knit "$@"
