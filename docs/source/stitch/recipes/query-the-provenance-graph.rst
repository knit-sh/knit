..
   title: Query the provenance graph
   categories: query
   order: 20
   description: Run read-only Cypher over the provenance graph with query graph — nodes are tables, edges are call and used_by relationships.
   apis: query:graph, knit_as

``query graph`` runs a read-only **Cypher** query against the provenance
database (via the bundled knit-graph engine). A node is a row, labelled by its
table; an edge is a ``__provenance__`` relationship --- ``call`` (a command
invoked another) or ``used_by`` (a setup was consumed by a later command). Pass
the statement with ``--exec``:

.. code-block:: console

   $ ./exp.sh query graph --exec \
       "MATCH (m:montecarlo)-[:call]->(r:runs) RETURN m.id, r.procs"

Labels are the table names from *Discover the schema*; a command that records
under a different table name can be written **either** way (``submit`` or
``jobs``), because knit hands the engine the live name map. Backtick-quote a
label that contains a colon: ``(s:`setup:libs`)``.

Edges carry the columns from ``__provenance__``, including the optional alias
set with ``knit_as`` (see *Distinguish repeated calls*), so repeated calls can be
told apart:

.. code-block:: console

   $ ./exp.sh query graph --exec \
       "MATCH (m:montecarlo)-[e]->(r:runs) WHERE e.alias = 'fast' RETURN r.procs"

Two flags help while you build a query: ``--explain`` prints the SQL knit-graph
would run instead of running it (hand it to ``query sql`` to tweak), and ``--ast``
prints the parsed syntax tree without touching the database. Shape the result
with the shared ``--format`` / ``--header`` / ``--separator`` options described in
*Run raw SQL*; anything after a trailing ``--`` is forwarded to knit-graph
verbatim. When a construct falls outside knit-graph's Cypher subset, drop to
``query sql``.
