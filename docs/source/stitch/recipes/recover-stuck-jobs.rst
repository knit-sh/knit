..
   title: Recover jobs stuck at running
   categories: jobs
   order: 70
   description: Correct jobs that a hard SIGKILL left stuck at running/submitting to their true terminal state, then retry them.
   apis: job:reconcile, submit:drain

When a compute node crashes, runs out of memory, or a drainer process is
hard-killed, the scheduler terminates the job with ``SIGKILL``. The knit
compute-side kill trap has no chance to run, so the job's database row stays
``running`` indefinitely. ``job reset`` and ``submit drain --retry`` will not
touch it, because both require a terminal state (``killed`` / ``failed``) before
they re-queue a row.

``job reconcile`` bridges the gap. It walks every ``running`` or ``submitting``
row in the database, reads the per-job ``.job.id`` file that the scheduler
assigned at dispatch time, and asks the scheduler for the job's true fate. The
verdict drives a state correction:

- **running** --- the job is genuinely alive; the row is left unchanged.
- **completed** / **failed** / **killed** --- the row is updated to match.
- **unknown** (no scheduler record) --- the row is moved to ``killed`` (a job
  the scheduler cannot confirm active is not a success).

The write is conditional (``WHERE state IN ('running','submitting')``), so a
kill trap that fires concurrently always wins a close race.

Run it by group to scope it to a single sweep, or without a selector to walk
the entire database:

.. code-block:: console

   $ ./exp.sh job reconcile --group sweep
   Reconciled 2 job(s); left 1 running.

   $ ./exp.sh job reconcile --dry-run    # inspect without writing
   $ ./exp.sh job reconcile --id "$id"   # one job by UUID

The job used as the example here always completes, so a stuck row is recovered
as ``killed`` (the scheduler reports its PID gone with no exit record):

.. knit-code:: /_code/reconcile.sh
   :language: bash
   :start-after: # START sim
   :end-before: # END sim

**Recover and retry in one drain pass.** ``submit drain --reconcile`` folds the
reconcile step into the drain loop: before releasing any prepared job it corrects
every stuck row in the drain's ``--group``/``--type`` scope, then ``--retry``
re-queues the newly-killed rows, and the drain releases them. This is the pattern
a re-submittable pilot uses to survive a hard cluster kill:

.. code-block:: console

   # inside the (re-submittable) pilot body
   $ ./exp.sh submit drain --group sweep --reconcile --retry killed --max-retries 3

Order inside the pass is always: reconcile → retry → drain. ``--reconcile`` is
skipped under ``--dry-run``. Combined with ``--retry``, a single pilot
submission can recover, re-queue, and complete an entire batch that was
interrupted mid-flight by a hard scheduler kill.

**Pilot sub-jobs.** A sub-job submitted inside a pilot job runs under the
in-allocation daemon, not the batch scheduler, so the scheduler cannot answer for
it directly. ``job reconcile`` handles this by walking from the stuck sub-job to
its **parent pilot** --- which *is* an ordinary scheduler job --- and asking the
scheduler for the parent's fate: if the pilot is gone, its orphaned sub-jobs died
with the allocation and are marked ``killed``; if the pilot is still running, the
sub-jobs are left alone. So a ``job reconcile`` run from the login node after a
hard-killed pilot correctly recovers the sub-jobs it left stuck, and running it
against a live pilot never false-kills a sub-job that is still working.

See *Retry failed or killed jobs* for the retry mechanics and *Run many jobs in
one allocation (pilot jobs)* for the pilot pattern.
