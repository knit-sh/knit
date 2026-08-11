..
   title: Run raw SQL
   categories: query
   order: 30
   description: Run a read-only SQL query with query sql, and shape any query's output with the shared --format, --header, and --separator options.
   apis: query:sql

When Cypher is more than you need --- or less than you need --- ``query sql``
runs a read-only SQL statement directly against the experiment database. Every
recorded table is a plain SQL table (see *Discover the schema*), so joining
across the ``__provenance__`` edges is just a join:

.. code-block:: console

   $ ./exp.sh query sql --exec "SELECT id, procs FROM runs ORDER BY procs DESC"
   $ ./exp.sh query sql --exec \
       "SELECT m.pi FROM montecarlo m
          JOIN __provenance__ e ON e.source_id = m.id AND e.edge_type = 'call'
          JOIN mcrank a ON a.id = e.target_id WHERE a.rank = 0"

Only read-only statements are accepted --- the query must start with
``SELECT``/``WITH``/``EXPLAIN``/``PRAGMA`` and contain no write keyword --- so a
query can never mutate the provenance database.

**Shaping the output** is the same for ``query sql`` and ``query graph``. Three
options control it:

.. code-block:: console

   $ ./exp.sh query sql --format json  --exec "SELECT id, procs FROM runs"
   $ ./exp.sh query sql --format csv --header --exec "SELECT id, procs FROM runs"
   $ ./exp.sh query sql --separator $'\t' --exec "SELECT id, procs FROM runs"

- ``--format`` picks the output mode: ``list`` (the default, one script-friendly
  row per line), ``json``, ``csv``, ``box``, ``markdown``, ``column``, and the
  other sqlite modes.
- ``--header`` adds a header row. It is **off by default**, because query output
  is most often piped into another tool where a header is noise.
- ``--separator`` sets the column separator (defaults to the backend's own).

``list`` output with no header makes ``query sql`` easy to capture in a script:
``procs="$(./exp.sh query sql --exec 'SELECT procs FROM runs LIMIT 1')"``. Like
all of ``query``, it needs a bootstrapped experiment.
