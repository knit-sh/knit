#!/bin/bash

# doc-check: source-only
#
# Showcase for the "Use a full Spack manifest" recipe: a setup that describes its
# Spack environment with a complete spack.yaml manifest, in both the file form and
# the inline here-doc form of @with_spack_env.
#
# Source-only: building a Spack environment needs a provisioned Spack, a compiler,
# and network access, none of which run in plain CI, so check-docs only
# syntax-checks this file.

source knit.sh

# START env-file
# Point @with_spack_env at a spack.yaml checked in next to the experiment.
# The manifest gives full control (versions, variants, compilers, views).
@setup "libs" "Build dependencies from a spack.yaml."
@with_spack_env "spack.yaml"
_libs_setup() {
    # cmake/hdf5/... from the manifest are on PATH here; build into the prefix.
    echo "building in ${KNIT_SETUP_PREFIX}"
}
@done
# END env-file

# START env-stdin
# Or inline the manifest with a here-doc when it is short and experiment-specific.
@setup "libs_inline" "Build deps from an inline manifest."
@with_spack_env <<'EOF'
spack:
  specs:
    - hdf5@1.14 +mpi
    - fftw
  view: true
EOF
_libs_inline_setup() {
    echo "building in ${KNIT_SETUP_PREFIX}"
}
@done
# END env-stdin

knit "$@"
