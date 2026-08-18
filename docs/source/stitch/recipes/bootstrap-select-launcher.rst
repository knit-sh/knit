..
   title: Select the MPI launcher
   categories: bootstrap
   order: 50
   description: Pin the MPI launcher instead of auto-detecting it.
   apis: bootstrap, knit_provides_launcher

By default ``bootstrap`` **auto-detects** the MPI launcher. ``--launcher`` is one
of ``auto``, ``openmpi``, ``mpich``, ``pals``, ``flux``, ``slurm``, ``pbs``,
``none``. With ``auto`` an MPI-native launcher (``openmpi``, ``mpich``, or
``pals``) is detected from the environment; if none is found and a batch
scheduler is present, ``auto`` falls back to that scheduler's integrated launcher
(``slurm`` = ``srun``, ``pbs`` = the PBS ``mpiexec`` wrapper, ``flux`` =
``flux run``). Select ``slurm``/``pbs``/``flux`` explicitly to force the
scheduler-integrated launcher even when an MPI-native one is present:

.. code-block:: console

   $ ./exp.sh bootstrap --launcher openmpi
   $ ./exp.sh bootstrap --launcher slurm

Use ``--launcher none`` to declare the machine offers no integrated MPI launcher
--- a setup's ``knit_provides_launcher`` then supplies one:

.. code-block:: console

   $ ./exp.sh bootstrap --launcher none
