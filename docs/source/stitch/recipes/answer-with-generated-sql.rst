..
   title: Answer with generated SQL
   categories: ai
   order: 30
   description: Turn a question into one read-only SQL query with ai query — the model writes the SQL, knit runs it read-only and self-corrects on error.
   apis: ai:query

``ai query`` answers a question by translating it into exactly **one** read-only
SQL statement, running it against the experiment database, and printing the
result. The model is seeded with the live schema (see *Discover the schema*), so
it writes queries against your actual tables and columns:

.. code-block:: console

   $ export OPENAI_API_KEY=sk-...
   $ ./exp.sh ai query --question "average procs per run, by app"

The generated statement passes through the same read-only guard as ``query sql``
--- it must start with ``SELECT``/``WITH``/``EXPLAIN``/``PRAGMA`` and contain no
write keyword. If a statement is rejected or sqlite reports an error, knit feeds
the error back to the model and it tries again, up to ``--max-iterations`` rounds
(default ``3``).

To review the SQL before trusting it, ask for it without running it:

.. code-block:: console

   $ ./exp.sh ai query --question "average procs per run, by app" --query-only

The output is shaped by the sqlite dot-command options:

- ``--format`` picks the mode: ``box`` (the default), ``column``, ``csv``,
  ``json``, ``line``, ``list``, ``markdown``, ``table``, ``html``.
- ``--no-header`` omits the header row (headers are **on** by default here,
  unlike ``query sql``); ``--separator`` sets the column separator for
  ``csv``/``list``.
- ``--model`` overrides the model for this call and ``--verbose`` streams each
  generated statement and any sqlite error to stderr.

Use ``ai query`` when you want data back and would rather not hand-write the SQL;
reach for *Run raw SQL* when you already know the query, and *Ask a
natural-language question* when you want a reasoned prose answer over several
read-only tools.
