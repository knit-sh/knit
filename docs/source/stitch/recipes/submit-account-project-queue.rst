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
