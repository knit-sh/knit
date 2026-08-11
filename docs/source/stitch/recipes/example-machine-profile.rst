..
   title: Anatomy of a machine profile
   categories: profiles
   order: 30
   description: A walkthrough of a real profile (ALCF Polaris) — its scheduler, launcher, hardware, modules, and Spack sections.
   apis: bootstrap, profile:show

A profile is a JSON document describing one machine. Here is the profile knit
ships for ALCF Polaris:

.. literalinclude:: /_code/polaris.json
   :language: json

Reading it top to bottom:

- ``description`` --- a one-line human summary, shown by ``profile list`` and
  ``profile show``.
- ``_hide`` --- when ``true``, keeps the profile out of ``profile list`` unless
  ``--hidden`` is passed. Use it for internal or work-in-progress profiles; the
  profile still resolves by name.
- ``scheduler`` --- the batch system. ``type`` (``pbs`` here) selects the backend
  knit uses to write directives and submit; ``command`` is the submit binary;
  ``default_queue`` and ``default_args`` become the experiment's defaults; and
  ``queues`` records each queue's node/walltime bounds so ``submit`` can validate
  a request against the queue before it reaches the scheduler.
- ``launcher`` --- how MPI ranks are launched. ``type`` (``pals``) picks the
  launcher backend for ``knit run``, and ``command`` is its binary
  (``mpiexec``).
- ``hardware`` --- ``cores_per_node`` and ``gpus_per_node``, used as the defaults
  for whole-node placement (``--default-cpus-per-node``, ``--gpus-per-node``) and
  readable from a script with ``knit_get_profile_field``.
- ``modules`` --- environment modules to ``module load`` before anything runs, so
  setups and jobs start from the machine's supported programming environment
  (here ``PrgEnv-gnu``).
- ``spack`` --- Spack configuration merged into every Spack environment knit
  builds. Its keys are Spack config sections (``packages`` here); knit writes them
  back verbatim, so this is just Spack config. Polaris registers the vendor MPI
  (``cray-mpich``) and ``libfabric`` as non-buildable **externals** pointing at
  the system install, and makes the virtual ``mpi`` package ``require``
  ``cray-mpich`` --- so any setup that asks Spack for ``mpi`` gets the tuned Cray
  stack instead of building its own.

The whole document is frozen into the experiment's metadata at bootstrap, so
``bootstrap --profile anl/polaris`` gives every command on that machine the same
scheduler, launcher, hardware, and Spack defaults. To author your own, see
*Write a machine profile*.
