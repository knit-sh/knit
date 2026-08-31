..
   title: Register and submit a job
   categories: jobs
   order: 10
   description: Register a command as a job and submit it to the scheduler with knit submit.
   apis: knit_register_job, submit, knit_with_setup

Register a job with ``knit_register_job`` instead of ``knit_register``. A job is a
command that runs *asynchronously* --- knit hands it to the batch scheduler
(Slurm, PBS, ...) rather than running it in the foreground --- and, on a cluster,
on other machines. The declaration block is otherwise identical to a plain
command: bind it to a software environment with ``knit_with_setup``, declare its
parameters, and define the body:

.. knit-code:: /_code/julia_job.sh
   :language: bash
   :start-after: # START job
   :end-before: # END job

Jobs are subcommands of the builtin ``submit`` dispatcher, so you launch one by
naming it after ``--``. Scheduler options (nodes, walltime, queue, ...) go
*before* the ``--``; the job's own parameters go *after* it:

.. code-block:: console

   $ ./exp.sh submit --nodes 2 --walltime 01:00:00 -- julia --width 1920 --height 1080
   018f9c3a-7b2e-7c41-9d0a-1f2e3d4c5b6a

``submit`` prints the new job's UUID on stdout and returns immediately (add
``--wait`` to block; see *Wait for and inspect a job*). Capture the UUID to track
the job later:

.. code-block:: console

   $ id=$(./exp.sh submit --nodes 2 -- julia --width 1920)
   $ ./exp.sh job status --id "$id"

If a job declares ``knit_with_setup``, name the setup instance to run in with
``submit --setup <name>``. See *Depend on a setup* for how a job is bound to its
environment, and *Provide the default setup* for the environment a job adopts when
it declares no setup.
