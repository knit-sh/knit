..
   title: Request resources for a job
   categories: jobs
   order: 16
   description: Ask the scheduler for nodes, walltime, and GPUs with submit --nodes/--walltime/--gpus-per-node.
   apis: submit

The resources a job needs are ``submit`` options, so they go *before* the ``--``:

.. code-block:: console

   $ ./exp.sh submit --nodes 4 --walltime 02:30:00 --gpus-per-node 2 -- julia

- ``--nodes`` (default ``1``) is the number of nodes. Knit allocates **whole
  nodes exclusively**: the per-node core count comes from the machine profile (or
  bootstrap detection), so there is no per-job CPU-count option --- a job gets all
  the cores on each node it is given.
- ``--walltime`` is the wall-clock limit as ``HH:MM:SS``. If you omit it, knit
  fills one in, in this order: the project default set with ``bootstrap
  --default-walltime``, then the selected queue's default (or maximum) from the
  machine profile, and finally one hour.
- ``--gpus-per-node`` (default ``0``) requests GPUs per node on a GPU partition.

These values become the scheduler directives in the generated batch script (which
you can inspect with ``job show:script``) and are recorded in the ``jobs`` table,
so a run's resource request travels with its records.
