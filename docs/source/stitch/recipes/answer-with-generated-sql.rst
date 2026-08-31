..
   title: Answer with a generated query
   categories: ai
   order: 30
   description: Turn a question into one read-only SQL or Cypher query with ai query — the model writes it, knit runs it read-only and self-corrects on error.
   apis: ai:query

``ai query`` answers a question by translating it into exactly **one** read-only
query, running it against the experiment, and printing the result. It works over
any experiment that records runs --- a command with an output and a table:

.. knit-code:: /_code/ai_query.sh
   :language: bash
   :start-after: # START montecarlo
   :end-before: # END montecarlo

The model is seeded with the live schema and the provenance name map (see
*Discover the schema*), so it writes against your actual tables, columns, and
edges:

.. code-block:: console

   $ export OPENAI_API_KEY=sk-...
   $ ./exp.sh ai query --question "average pi per seed"

**SQL or Cypher --- the model chooses.** By default (``--lang auto``) the model
picks the language that fits the question: SQL for filtering, aggregation, and
sorting within a table; Cypher (run by the bundled knit-graph engine) for
relationships across commands --- which command *called* which, or which setup a
job *used*:

.. code-block:: console

   $ ./exp.sh ai query --question "which setup did the montecarlo job use"

Pin the language with ``--lang sql`` or ``--lang cypher`` when you already know
which you want; that also narrows the system prompt to a single language so the
model is not tempted by the other. Whichever language is used, the generated
statement passes through the same read-only guard as ``query sql`` / ``query
graph`` --- it must start with a read clause (``SELECT``/``WITH``/``EXPLAIN``/
``PRAGMA`` for SQL; ``MATCH``/``OPTIONAL MATCH`` for Cypher) and contain no write
keyword. If a statement is rejected or the backend reports an error, knit feeds
the error back to the model and it tries again, up to ``--max-iterations`` rounds
(default ``3``).

To review the query before trusting it, ask for it without running it ---
``--query-only`` prints the generated statement and its detected language:

.. code-block:: console

   $ ./exp.sh ai query --query-only --question "average pi per seed"
   SELECT seed, avg(pi) FROM montecarlo GROUP BY seed

The output is shaped by the shared query options:

- ``--format`` picks the mode from the ``query_format`` set: ``box`` (the default
  here), ``column``, ``csv``, ``json``, ``line``, ``list``, ``markdown``,
  ``table``, ``html``, ``ascii``, ``tabs`` --- and it applies identically whether
  the answer came back as SQL or Cypher.
- ``--no-header`` omits the header row (headers are **on** by default here,
  unlike ``query sql``); ``--separator`` sets the column separator for
  ``csv``/``list``.
- ``--model`` overrides the model for this call and ``--verbose`` streams the
  chosen language, each generated statement, and any backend error to stderr.

Use ``ai query`` when you want data back and would rather not hand-write the
query; reach for *Run raw SQL* or *Query the provenance graph* when you already
know it, and *Ask a natural-language question* when you want a reasoned prose
answer over several read-only tools.
