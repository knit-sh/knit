..
   title: Time each job and prove node non-overlap
   categories: jobs
   order: 22
   description: Read each job's prepared/submitted/started/ended timestamps to compute run durations and prove no two jobs shared a node at the same time.
   apis: submit, job:status, query:sql

Every ``jobs`` row records four lifecycle timestamps, one per transition:
``prepared_at`` (the row was built), ``submitted_at`` (it was sent to the
scheduler), ``started_at`` (its body began, on the compute node), and
``ended_at`` (it reached ``completed`` / ``failed`` / ``killed``). Each stays
``NULL`` until its transition happens, so a job killed in the queue has a
``started_at`` of ``NULL``, and a still-``prepared`` job has only
``prepared_at``.

The values are stored in **UTC** as ``YYYY-MM-DD HH:MM:SS.sss`` strings --- a
form that sorts lexically in time order and parses in SQLite's ``datetime()`` and
``julianday()`` on any version. ``job status`` renders them in your own local
zone (see *Wait for and inspect a job*); a raw ``query sql`` prints the stored
column verbatim, so wrap any displayed timestamp in ``datetime(col, 'localtime')``
to read it in local time:

.. code-block:: console

   $ ./exp.sh query sql --exec \
       "SELECT id, state,
               datetime(started_at, 'localtime') AS started,
               datetime(ended_at,   'localtime') AS ended
          FROM jobs ORDER BY id"

**Run duration.** The arithmetic is zone-independent, so it runs on the stored
UTC columns directly. ``julianday`` returns days; multiply by ``86400`` for
seconds:

.. code-block:: console

   $ ./exp.sh query sql --exec \
       "SELECT id, hostnames,
               (julianday(ended_at) - julianday(started_at)) * 86400.0 AS seconds
          FROM jobs
         WHERE started_at IS NOT NULL AND ended_at IS NOT NULL"

**No two jobs on one node at once.** This is the payoff for a pilot sweep: the
``hostnames`` column records the node each (sub-)job ran on, and the timestamps
record its window. A self-join over same-node rows with overlapping
``[started_at, ended_at]`` intervals returns a row for every double-booking ---
so an **empty result proves** no two jobs shared a node at the same time. The
comparison is on the stored UTC columns (correct and version-safe); only the
displayed columns are localised:

.. code-block:: console

   $ ./exp.sh query sql --exec \
       "SELECT a.id, b.id, a.hostnames,
               datetime(a.started_at, 'localtime') AS a_started,
               datetime(b.started_at, 'localtime') AS b_started
          FROM jobs a JOIN jobs b
            ON a.hostnames = b.hostnames
           AND a.id < b.id
           AND a.started_at < b.ended_at
           AND b.started_at < a.ended_at"

Run every query through ``query sql --exec`` so it goes over the read-only lens;
never reach for the bundled ``sqlite3`` by hand. ``job reset`` clears a retried
job's ``submitted_at`` / ``started_at`` / ``ended_at`` back to ``NULL`` (keeping
the original ``prepared_at``), and ``job reconcile`` stamps ``ended_at`` when it
drives a stuck row to a terminal state --- see *Retry failed or killed jobs* and
*Recover jobs stuck at running*.
