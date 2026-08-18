..
   title: Select the batch scheduler
   categories: bootstrap
   order: 40
   description: Pin the batch scheduler instead of auto-detecting it.
   apis: bootstrap

By default ``bootstrap`` **auto-detects** the batch scheduler. Pin it explicitly
when detection guesses wrong, or to make the experiment self-documenting.
``--scheduler`` is one of ``auto``, ``slurm``, ``pbs``, ``flux``, ``local``,
``none``:

.. code-block:: console

   $ ./exp.sh bootstrap --scheduler slurm

Use ``--scheduler local`` to run jobs as plain local processes with no batch
system. Use ``--scheduler none`` for a self-managed cluster (no scheduler) and
pair it with ``--default-nodefile`` so a job can report its allocation:

.. code-block:: console

   $ ./exp.sh bootstrap --scheduler none --default-nodefile hosts.txt
