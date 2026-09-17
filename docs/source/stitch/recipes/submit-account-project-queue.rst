..
   title: Set the scheduler account, project, and queue
   categories: jobs
   order: 18
   description: Override the accounting and queue for one submission, and set project-wide defaults at bootstrap.
   apis: submit, bootstrap

Clusters charge jobs to an account/project and run them in a named queue (or
partition). ``submit`` takes all three as options; they go before the ``--``:

.. code-block:: console

   $ ./exp.sh submit --account m1234 --queue debug -- julia

Each one defaults so you rarely pass it per submission:

- ``--account`` defaults to the ``__account__`` metadata.
- ``--project`` defaults to the ``__project__`` metadata.
- ``--queue`` defaults to the ``__default_queue__`` metadata, then to the machine
  profile's default queue.

Set the metadata defaults once, at bootstrap, so every ``submit`` inherits them:

.. code-block:: console

   $ ./exp.sh bootstrap --account m1234 --project julia-sets

After that, a bare ``submit`` uses those values, and the options above are only
for overriding them on a single run. The resolved values are written into the
batch script's directives and recorded with the job.

Let knit pick the queue with ``--queue auto``: it walks the machine profile's
declared queues in order and selects the first whose node and walltime bounds
accept the job as you specified it.

.. code-block:: console

   $ ./exp.sh submit --queue auto --nodes 4 --walltime 02:00:00 -- julia

Selection uses only what you asked for --- the node count, and the walltime only
when you gave one --- and resolves to a concrete queue that is recorded with the
job (never the literal ``auto``). If no declared queue fits, ``submit`` stops with
a per-queue explanation instead of letting the scheduler reject the request. Make
it the default for every submission by storing it at bootstrap, or by setting
``default_queue`` to ``"auto"`` in the machine profile:

.. code-block:: console

   $ ./exp.sh bootstrap --default-queue auto
