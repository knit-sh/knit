..
   title: Name a job and give it a stable alias
   categories: jobs
   order: 17
   description: Distinguish submit --name (a knit alias for the job) from --job-name (the scheduler's name).
   apis: submit

``submit`` has two different "name" options, for two different audiences.

``--name`` is a **stable alias inside knit** for this job instance. Knit symlinks
``<job-root>/<name>`` to the job's ``<uuid>`` directory and records the name in
the ``jobs`` table, so you can refer to a run by a memorable name instead of a
UUID. It must be unique within the experiment:

.. code-block:: console

   $ ./exp.sh submit --name hi-res-run -- julia --width 3840

``--job-name`` is the name the **scheduler** shows (``#SBATCH --job-name`` /
``#PBS -N``) --- what appears in ``squeue`` / ``qstat``. It defaults to the
experiment script name:

.. code-block:: console

   $ ./exp.sh submit --job-name julia-nightly -- julia

The two are independent: ``--name`` organizes runs within knit and never reaches
the scheduler, while ``--job-name`` only labels the job in the queue and is not a
handle knit tracks. Set either, both, or neither.
