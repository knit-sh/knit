..
   title: Build an MPI environment and provide a launcher
   categories: setup, spack
   order: 30
   description: Ask Spack for an MPI provider in a setup and expose it as the run launcher.
   apis: knit_register_setup, knit_with_spack_specs, knit_provides_launcher

Add ``mpi`` to a setup's ``knit_with_spack_specs`` so Spack provisions an MPI
implementation alongside the rest of the build environment; CMake then detects it
and builds the parallel binary. Calling ``knit_provides_launcher`` advertises that
Spack-built MPI as the launcher, so ``knit run`` can place ranks even on a machine
that has no MPI of its own.

.. literalinclude:: /_code/julia_mpi.sh
   :language: bash
   :start-after: # START setup
   :end-before: # END setup
