#!/bin/bash

# doc-check: source-only
#
# Showcase for the "Build an MPI environment and provide a launcher" recipe: a
# minimal setup that asks Spack for an MPI implementation and advertises it as the
# run launcher. The body has essentially nothing to do --- Spack installs MPI and
# knit activates it before the body runs.
#
# Source-only: building a Spack environment needs a provisioned Spack, a compiler,
# and network access, none of which run in plain CI, so check-docs only
# syntax-checks this file.

source knit.sh

# START setup
# Ask Spack for MPICH and expose it as the launcher. Activating the Spack
# environment (which knit does before the body runs) puts mpicc / mpirun on PATH,
# and @provides_launcher advertises that MPI to "knit run" --- so the body has
# nothing left to build.
@setup "mpienv" "Provide an MPI implementation via Spack."
@with_spack_specs "mpich"
@provides_launcher
_mpienv_setup() {
    : # nothing to do: Spack already installed and activated MPICH
}
@done
# END setup

knit "$@"
