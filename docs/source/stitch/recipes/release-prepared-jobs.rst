..
   title: Release prepared jobs
   categories: jobs
   order: 65
   description: Hand prepared jobs to the scheduler one at a time, by id or oldest-first, with a drain loop.
   apis: submit:next, submit:prepared

Once jobs are prepared (see *Prepare a job instead of submitting it*), release
them to the scheduler with two ``submit`` subcommands. ``submit next`` releases
the **oldest** prepared job, optionally restricted by job type (``--type``) or
group (``--group``); ``submit prepared --id`` releases one specific job. Both take
``--wait`` (block until the job finishes) but no scheduler options --- the
submission spec was frozen at prepare time:

.. code-block:: console

   $ ./exp.sh submit next --group sweep
   018f9c3a-7b2e-7c41-9d0a-1f2e3d4c5b6a
   $ ./exp.sh submit prepared --id 018f9c3a-7b2e-7c41-9d0a-1f2e3d4c5b6a

The claim is atomic --- picking and marking a job is one conditional update under
knit's write lock --- so several releasers may run concurrently (cron ticks, or a
loop keeping N jobs in flight) without ever double-submitting the same row.

``submit next`` returns **non-zero** when no prepared job matches, so a
fill-the-queue loop can drain a group and stop on its own:

.. code-block:: bash

   # Release every prepared job in the "sweep" group, oldest first.
   while ./exp.sh submit next --group sweep --wait; do :; done

Releasing advances the row ``prepared -> submitted -> running -> completed`` (or
``killed``); the id never changes, so the job you prepared and the job that ran
are the same recorded artifact.
