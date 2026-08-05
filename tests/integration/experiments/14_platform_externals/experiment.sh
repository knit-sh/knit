#!/usr/bin/env bash
# Integration test experiment 14_platform_externals.
#
# Exercises profile-provided Spack externals: a machine profile declares a
# system package as a non-buildable external (rendered by bootstrap into
# .knit/packages.yaml), and a Spack-backed setup requests that same package as a
# spec. Spack must concretize the spec to the profile's external and install
# nothing into the knit-private Spack (the external is used, not rebuilt).
#
# Registers:
#   - a Spack-backed setup "makeenv" declared with knit_with_spack_specs "gmake":
#     knit creates a Spack environment for the spec, merges .knit/packages.yaml
#     (the profile's externals) into it, and installs. With gmake marked
#     buildable: false and pointed at the system prefix, concretization resolves
#     gmake to the external and builds nothing.
#
# Because a registered setup declares a Spack environment, bootstrap
# auto-provisions the knit-private Spack (the M4 -> M2 wiring) even without an
# explicit --spack. The profile's externals reach the env because
# _knit_spack_env_install merges .knit/packages.yaml before concretization.

source knit.sh

knit_set_program_description \
    "Profile-provided Spack externals integration test experiment."

knit_register_setup "makeenv" __makeenv_setup \
    "Build a Spack environment whose gmake resolves to a profile external."
knit_with_spack_specs "gmake"
__makeenv_setup() {
    # The Spack environment is already built and activated by the time this body
    # runs; gmake came from the profile's external, so nothing was compiled.
    export SPACK_SETUP_MARKER="makeenv-built"
}
knit_done

knit "$@"
