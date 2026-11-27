..
   title: Wait for and inspect a job
   categories: jobs
   order: 30
   description: Block on a job, check its lifecycle state, and show its recorded parameters.
   apis: submit, job:wait, job:status, job:show

A submitted job moves through lifecycle states --- ``submitted`` → ``running`` →
``completed``, or ``killed`` if the scheduler terminates it. Knit records the
state in the ``jobs`` table keyed by the job's UUID.

To submit and block in one step, add ``--wait``: ``submit`` then returns the
job's own exit code, so it composes in a script like any foreground command:

.. code-block:: console

   $ ./exp.sh submit --wait -- julia --width 1920 && echo "render ok"

To block on an already-submitted job, use ``job wait``. It waits on the scheduler
itself (not by polling the database), prints the terminal state, and exits
non-zero if the job was killed:

.. code-block:: console

   $ id=$(./exp.sh submit -- julia --width 1920)
   $ ./exp.sh job wait --id "$id"
   completed

Check the current state without blocking with ``job status``. It prints the
state on the first line, then the four lifecycle timestamps
(prepared/submitted/started/ended), each shown in your local time zone with an
explicit offset (a stage not yet reached shows ``-``):

.. code-block:: console

   $ ./exp.sh job status --id "$id"
   running
   prepared_at:  2026-11-27 03:28:05 (-06:00)
   submitted_at: 2026-11-27 03:28:06 (-06:00)
   started_at:   2026-11-27 03:28:07 (-06:00)
   ended_at:     -

See everything recorded for the job --- its submission options and its own
parameters --- with ``job show`` (add ``--json`` for machine-readable output):

.. code-block:: console

   $ ./exp.sh job show --id "$id"
   $ ./exp.sh job show --id "$id" --json
