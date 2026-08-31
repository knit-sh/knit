..
   title: Build an MPI environment and provide a launcher
   categories: setup, spack
   order: 30
   description: Ask Spack for an MPI provider in a setup and expose it as the run launcher.
   apis: knit_register_setup, knit_with_spack_specs, knit_provides_launcher

Add ``mpi`` (or a concrete provider like ``mpich`` or ``openmpi``) to a setup's
``knit_with_spack_specs`` so Spack provisions an MPI implementation as part of the
environment. Calling ``knit_provides_launcher`` then advertises that Spack-built
MPI as the launcher, so ``knit run`` can place ranks even on a machine that has no
MPI of its own:

.. knit-code:: /_code/mpi_setup.sh
   :language: bash
   :start-after: # START setup
   :end-before: # END setup

Because knit activates the Spack environment before the setup body runs, the MPI
compilers and launcher (``mpicc`` / ``mpirun``) are already on ``PATH`` --- the
body here has nothing left to do. In a real setup this is exactly where the
environment pays off: a downstream build (say a CMake ``find_package(MPI)``) now
finds the Spack MPI and produces a parallel binary, with no MPI-specific logic in
the setup itself.

The provided launcher is detected once at setup-build time and frozen into the
setup's ``.activate.sh`` (recorded as the ``__mpi_launcher__`` provenance output).
It sits *below* a machine's own launcher in precedence, so a profile's launcher
still wins when one exists; it only fills the gap on a machine that offers none.
