..
   title: Retry failed or killed jobs
   categories: jobs
   order: 68
   description: Re-queue terminal-failed jobs back to prepared so a later drain retries them.
   apis: job:reset, submit:drain

``prepare`` + ``submit drain`` is a durable queue: the backlog lives in the
database as ``prepared`` rows, so a drainer that dies leaves the un-started jobs
*still* ``prepared`` and re-running ``submit drain`` resumes them for free (see
*Drain a prepared batch with submit drain*). The gap is a job that was **in
flight** when the drainer died: it is no longer ``prepared``, so drain never
picks it up again. The common cause is draining inside a **pilot job** killed at
walltime --- its running subjobs end up ``killed`` (their pre-termination trap
fired) or ``failed``. Those are terminal states, so the work is lost unless you
put the job back in the queue.

``job reset`` does that. It moves a ``killed`` / ``failed`` job back to
``prepared`` and clears the stale run (the backend id, the recorded hostnames),
while keeping the job's directory, batch script, recorded arguments, and id --- so
a later ``submit drain`` re-runs it from the same inputs, under the same
provenance. It never touches ``running`` / ``submitting`` jobs (knit cannot know
they are dead) and only redoes a ``completed`` job with ``--force``:

.. code-block:: console

   $ ./exp.sh job reset --group sweep             # re-queue every killed/failed job in the group
   Reset 2 job(s) to prepared.
   $ ./exp.sh job reset --id 018f9c3a-7b2e-7c41-9d0a-1f2e3d4c5b6a
   $ ./exp.sh job reset --group sweep --state failed   # only the failed ones

Each reset increments the job's ``retries`` count, so a query can see how many
attempts a job took.

The job stands in here for one killed at walltime: it fails on its first attempt
and succeeds on the retry, because ``job reset`` preserves its directory (where it
left a marker):

.. knit-code:: /_code/retry.sh
   :language: bash
   :start-after: # START flaky
   :end-before: # END flaky

**Retry inside the drain.** ``submit drain --retry <states>`` folds the reset into
the drain: once at the start of the pass it re-queues every matching job in those
states (``killed`` and/or ``failed``, within the drain's ``--group`` / ``--type``
scope), then drains the prepared backlog. This is the one command a re-submittable
pilot runs:

.. code-block:: console

   # login node, once: prepare the whole batch
   $ ./exp.sh prepare --group sweep -- sim --n 5

   # inside the (re-submittable) pilot body: resume AND retry what a previous
   # pilot left behind
   $ ./exp.sh submit drain --group sweep --max-inflight 8 --retry killed,failed --max-retries 3

The reset is a one-shot snapshot taken at the start of the pass, so a job that
fails *again* during the same pass is left terminal for the **next** invocation ---
one pass cannot spin in an immediate retry loop. ``--max-retries <n>`` caps the
per-job retry count (via the ``retries`` column), so a **poison** job that always
fails is not retried without bound; it is left terminal with a warning. Leave
``--retry`` off and ``submit drain`` behaves exactly as before, releasing only
``prepared`` jobs.

See *Drain a prepared batch with submit drain* for the drain itself and *Prepare a
job instead of submitting it* for building the backlog.
