#!/bin/bash

# doc-check: source-only
#
# Showcase for the "Generate specs or a manifest with a function" recipe: a setup
# whose environment is produced by a user function at setup-invocation time,
# instead of a fixed list of specs or a static manifest.
#
# Source-only: building a Spack environment needs a provisioned Spack, a
# compiler, and network access, none of which run in plain CI, so check-docs only
# syntax-checks this file.

source knit.sh

# Spack is provided by a plugin. Import it before using its setup directives.
knit_import spack

# START specs_from
# A spec-generating function is called when the setup runs, with the setup's
# arguments as "$@"; it reads parameters with knit_get_parameter and prints
# newline-separated specs on stdout. It chooses specs *structurally* --- here a
# spec is added only when the --use-cuda flag is set --- and "{{...}}" still fills
# in values, so the two compose.
mllibs_specs() {
    echo "openblas@{{openblas-version}}"
    [[ "$(knit_get_parameter use-cuda "$@")" == true ]] && echo "py-torch +cuda"
}

@setup "mllibs" "Build an ML environment, optionally with CUDA."
@with_flag     "use-cuda" "Build the CUDA-enabled variant."
@with_required "openblas-version:string" "OpenBLAS version to build."
@with_spack_specs_from mllibs_specs
_mllibs_setup() {
    echo "building in ${KNIT_SETUP_PREFIX}"
}
@done
# END specs_from

# START env_from
# For a whole document (a complete spack.yaml / pyproject.toml), a function prints
# it on stdout. @with_spack_env_from is the programmatic twin of @with_spack_env;
# "{{...}}" is rendered on the printed document too.
mlenv_manifest() {
    cat <<YAML
spack:
  specs:
    - openblas@{{openblas-version}}
  view: true
  concretizer:
    unify: true
YAML
}

@setup "mlenv" "Build an ML environment from a generated manifest."
@with_required "openblas-version:string" "OpenBLAS version to build."
@with_spack_env_from mlenv_manifest
_mlenv_setup() {
    echo "building in ${KNIT_SETUP_PREFIX}"
}
@done
# END env_from

knit "$@"
