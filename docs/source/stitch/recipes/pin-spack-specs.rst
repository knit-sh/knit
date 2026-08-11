..
   title: Pin a setup's Spack specs
   categories: spack
   order: 10
   description: List the Spack packages a setup needs and let knit build them.
   apis: knit_with_spack_specs, knit_register_setup, KNIT_SETUP_PREFIX

For the common "just install these packages" case, list the Spack specs a setup
needs with ``knit_with_spack_specs``. Knit synthesizes a minimal ``spack.yaml``
and, before the setup body runs, installs the specs into a Spack environment and
activates it --- so the tools are on ``PATH`` / ``LD_LIBRARY_PATH`` when you build
into ``KNIT_SETUP_PREFIX``. The Spack it uses is knit's own, installed under
``.knit/`` and isolated from any Spack you have on the machine (see *Run Spack
directly* and *Isolate Spack from your personal config*); declaring a
Spack-backed setup makes ``bootstrap`` provision that Spack automatically:

.. literalinclude:: /_code/julia_setup.sh
   :language: bash
   :start-after: # START setup
   :end-before: # END setup

Each argument is a full Spack spec, so you can pin versions and variants the same
way you would on the ``spack install`` command line (for example
``knit_with_spack_specs "hdf5@1.14 +mpi" "fftw"``). The concrete manifest and
lockfile are captured as provenance outputs on the setup's table. For finer
control over the environment, use a full manifest with ``knit_with_spack_env``
instead.
