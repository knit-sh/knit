..
   title: Run many jobs in one allocation (pilot jobs)
   categories: jobs
   order: 60
   description: Mark a job a pilot so its body can submit sub-jobs that pack onto its own allocation.
   apis: knit_with_pilot, submit, job:wait

A single ``knit submit`` buys one allocation from the machine scheduler. To run
many smaller jobs *inside* that allocation --- a parameter campaign, an ensemble,
a many-task workload --- mark a job a **pilot** with ``knit_with_pilot``. When the
pilot job starts, knit launches a small in-allocation scheduler (the
``knit-pilotd`` daemon, provisioned at bootstrap like the other bundled tools)
over the job's own nodes. From then on a ``knit submit`` in the pilot's body goes
to that daemon instead of to Slurm/PBS, so the sub-jobs pack onto the allocation
and run concurrently --- with no second trip through the batch queue.

The body fans out the sub-jobs, keeping the UUID each ``knit submit`` returns, and
waits on the whole batch with ``knit job wait --id`` (which accepts a
comma-separated list):

.. knit-code:: /_code/pilot_job.sh
   :language: bash
   :start-after: # START campaign
   :end-before: # END campaign

Each sub-job is an ordinary knit job --- here a tiny ``worker`` --- so it records
its own row and a provenance ``call`` edge back to the pilot; a campaign is
queryable as a normal parent/child job graph:

.. knit-code:: /_code/pilot_job.sh
   :language: bash
   :start-after: # START worker
   :end-before: # END worker

Launch it like any job; give the pilot the nodes the sub-jobs will pack onto:

.. code-block:: console

   $ ./exp.sh submit --nodes 2 --wait -- campaign --count 4

Outside a pilot job, a ``knit submit`` from within a job body is rejected (it
would nest batch submissions) and the error names ``knit_with_pilot``. Two options
tune a pilot: ``knit_with_pilot --exclude-launch-host`` drops the daemon's own
node from the pool (for machines where the job script shares the first compute
node; a no-op otherwise), and ``knit_with_pilot --kill-on-exit`` kills any
sub-jobs still outstanding when the body returns instead of the default, which
**drains** them to completion first. Killing the pilot job itself tears the whole
sub-tree down: every running sub-job is signalled and every queued one dropped,
and all are recorded ``killed`` --- a killed pilot never leaves a sub-job running
or lost.
