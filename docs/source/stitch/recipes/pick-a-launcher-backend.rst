..
   title: Pick a launcher backend
   categories: apps
   order: 40
   description: Override the launcher knit run uses with --launcher, and pass launcher-native flags with --launcher-args.
   apis: run, bootstrap

``knit run`` selects a launcher automatically --- the one detected at bootstrap
or set with ``bootstrap --launcher`` (see *Select the MPI launcher*). Override it
for a single launch with ``--launcher``:

.. code-block:: console

   $ knit run --launcher openmpi --procs 16 -- render --output "${png}"

The supported backends are:

- ``none`` --- no launcher; runs the app as a single rank-0 process (rejects
  ``--procs`` > 1 and remote hosts). This is the laptop default.
- ``openmpi`` / ``mpich`` --- MPI-native launchers (``mpirun`` / ``mpiexec``).
- ``slurm`` / ``pbs`` / ``pals`` --- the scheduler's own launcher (``srun``,
  PBS ``mpiexec``, PALS ``mpiexec``), which reads the allocation natively.

Knit translates ``--procs``, ``--procs-per-node``, ``--hostnames``, and the
binding options into each backend's native flags. When a flag isn't covered, or
you need a launcher option knit doesn't model, pass it through verbatim with
``--launcher-args``:

.. code-block:: console

   $ knit run --launcher openmpi --procs 16 \
       --launcher-args "--map-by socket --report-bindings" -- render --output "${png}"

``--launcher-args`` is the escape hatch: its contents are appended to the
launcher command line unchanged, after the flags knit generates.
