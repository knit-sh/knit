..
   title: Drain a prepared batch with submit drain
   categories: jobs
   order: 66
   description: Release a whole prepared batch in one command, throttled to N jobs at once, optionally in the background.
   apis: submit:drain

Once a batch is prepared (see *Prepare a job instead of submitting it*), you
could release it by hand with a loop over ``submit next`` (see *Release prepared
jobs*). ``submit drain`` wraps that loop as one command: it releases prepared
jobs --- optionally filtered by ``--type`` (job name) or ``--group`` --- until the
matching queue is empty.

How fast they go out is set by ``--max-inflight``:

- **1** (the default) releases one job, waits for it, then releases the next ---
  serial;
- **N > 1** keeps at most ``N`` jobs alive in the scheduler at once, releasing the
  next whenever a slot frees --- a queue filler that never floods the scheduler;
- **0** releases every matching job back to back without waiting.

.. code-block:: console

   $ ./exp.sh submit drain --group sweep --max-inflight 4
   Released 12 job(s): 12 completed, 0 failed.

``--count N`` releases at most ``N`` jobs this run; ``--stop-on-failure`` stops
releasing new jobs once one fails --- a job whose body exits non-zero (state
``failed``) or that is killed (cancel / OOM / walltime) --- while in-flight jobs
still finish, and drain exits non-zero when any released job failed.
``--dry-run`` lists what *would* be released, in order, without claiming
anything, and ``--json-summary`` prints a machine-readable object to stdout:

.. code-block:: console

   $ ./exp.sh submit drain --group sweep --dry-run
   018f9c3a-7b2e-7c41-9d0a-1f2e3d4c5b6a  sim  [sweep]
   018f9c3a-8c3f-7d52-ae1b-2f3e4d5c6b7c  sim  [sweep]
   $ ./exp.sh submit drain --group sweep --json-summary
   {"released":2,"completed":2,"failed":0,"drained":true,"stopped":false,"dry_run":false}

Draining a large batch can take a while, so ``--detached`` runs the whole loop in
the background and returns at once --- pick the backend with ``--detach-backend``
(``auto`` tries ``tmux``, then ``screen``, then ``nohup``). Output is always
written to a log, and drain prints how to reattach, follow it, and stop it:

.. code-block:: console

   $ ./exp.sh submit drain --group sweep --max-inflight 4 --detached
   Draining in the background (tmux session "knit-drain-20260921-142530").
     Reattach: tmux attach -t knit-drain-20260921-142530
     Log:      tail -f .knit/drain/knit-drain-20260921-142530.log
     Stop:     tmux kill-session -t knit-drain-20260921-142530

Stopping the session stops *further* releases; jobs already handed to the
scheduler keep running (use ``job cancel`` for those). Like ``submit next``,
draining records nothing of its own --- each release advances an existing
``jobs`` row --- so the jobs you prepared and the jobs that ran are the same
recorded rows.
