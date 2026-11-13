#!/bin/bash

# doc-check: source-only
#
# Showcase for the "Make a spec depend on a parameter" recipe: a setup whose
# Spack spec carries a "{{parameter}}" placeholder, rendered from the setup's
# parameter value when the setup runs.
#
# Source-only: building a Spack environment needs a provisioned Spack, a
# compiler, and network access, none of which run in plain CI, so check-docs only
# syntax-checks this file.

source knit.sh

# Spack is provided by a plugin. Import it before using its setup directives.
knit_import spack

# START specs
# A "{{parameter}}" placeholder in a spec is replaced, when the setup runs, with
# the value of the named setup parameter. @with_spack_specs takes one or more
# specs, and several calls add up into one spec list.
@setup "mathlibs" "Build math libraries at chosen versions."
@with_required "openblas-version:string" "OpenBLAS version to build."
@with_optional "fftw-spec:string" "fftw" "fftw spec (e.g. 'fftw@3.3.10 +openmp')."
@with_spack_specs "openblas@{{openblas-version}}" "{{fftw-spec}}"
_mathlibs_setup() {
    # openblas and fftw at the chosen versions are on PATH / LD_LIBRARY_PATH here.
    echo "building in ${KNIT_SETUP_PREFIX}"
}
@done
# END specs

knit "$@"
