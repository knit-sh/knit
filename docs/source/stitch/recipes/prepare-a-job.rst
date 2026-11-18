..
   title: Prepare a job instead of submitting it
   categories: jobs
   order: 60
   description: Build and record a job without dispatching it, leaving it queued as a prepared row.
   apis: prepare, job:cancel

``submit`` does two things at once: it *builds* a job (validate it, create its
directory, generate the batch script, record the row) and it *dispatches* that
job to the scheduler. ``prepare`` does only the first half. It mirrors ``submit``
argument-for-argument --- over the same job registry, so you prepare the same
jobs you submit --- but stops before the scheduler, leaving a row in state
``prepared``:

.. knit-code:: /_code/prepare.sh
   :language: bash
   :start-after: # START job
   :end-before: # END job

Prepare the job the way you would submit it, but with ``prepare`` (note there is
no ``--wait`` --- nothing is dispatched yet). ``--group`` tags related runs with a
free-form label you can filter on later:

.. code-block:: console

   $ ./exp.sh prepare --group sweep -- sim --n 5
   018f9c3a-7b2e-7c41-9d0a-1f2e3d4c5b6a

The whole submission spec --- backend, nodes, walltime, queue, setup, and the
job's own arguments --- is frozen at prepare time and baked into the batch script,
so releasing the job never re-opens those options. A prepared job is an ordinary
``jobs`` row, so it needs no new listing command: ``job list --status prepared``
shows them (add ``--types`` to narrow by job type):

.. code-block:: console

   $ ./exp.sh job list --status prepared

The frozen **backend** is the scheduler ``prepare`` detected where you ran it. That
is wrong when the job will be released somewhere else --- most often a job prepared
on a login node but drained *inside a pilot allocation*, where the real backend is
the pilot daemon, not Slurm/PBS. Pass ``--backend pilot`` to freeze it for the
pilot instead (no site queue, no wall-clock cap). A release only happens where the
ambient backend matches the frozen one, so a pilot-bound job is drained inside the
pilot and skipped (with a count) by a drain run anywhere else --- never replayed
against the wrong scheduler:

.. code-block:: console

   $ ./exp.sh prepare --backend pilot --group sweep -- sim --n 5

A prepared job has contacted no scheduler, so ``job cancel`` simply removes it ---
its row, its directory, and any ``--name`` alias --- with nothing to cancel
remotely:

.. code-block:: console

   $ ./exp.sh job cancel --id 018f9c3a-7b2e-7c41-9d0a-1f2e3d4c5b6a

See *Release prepared jobs* for how to hand a prepared job to the scheduler, and
*Prepare many jobs from a plan* for preparing a whole batch at once.
