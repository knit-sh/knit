..
   title: Trace an artifact back to its producer
   categories: query, artifacts
   order: 70
   description: Recover which invocation produced a file by walking the produced edge from its artifacts row back to the producing command.
   apis: query:graph, query:sql, knit_with_artifact

Each artifact is recorded as one row in the ``artifacts`` table (its ``path``,
``name``, ``type``, ``checksum``, and ``result``), linked to the invocation that
made it by a ``produced`` provenance edge --- **not** as a column of the
producing command's own table (see *Declare and bind an artifact*). So *which
invocation produced this file?* is a reverse walk of that edge, keyed on the
artifacts-relative ``path``.

With ``query graph`` the walk is a Cypher match. The producing node needs no
label --- read the producer off the edge, so the same query works no matter which
command made the file:

.. code-block:: console

   $ ./exp.sh query graph --format column --header --exec \
       "MATCH (t)-[e:produced]->(a:artifacts)
          WHERE a.path = 'table.csv'
          RETURN e.source_name, e.source_id"

``e.source_name`` is the producing command and ``e.source_id`` is its invocation
id, which joins back to that command's own recorded row for the rest of the
provenance (its parameters, its ``call`` edge to a parent, and so on).

The same lookup in ``query sql`` joins the ``artifacts`` row to the
``__provenance__`` edge on the artifact id:

.. code-block:: console

   $ ./exp.sh query sql --format column --header --exec \
       "SELECT p.source_name, p.source_id
          FROM artifacts a
          JOIN __provenance__ p ON p.target_id = a.id AND p.edge_type = 'produced'
         WHERE a.path = 'table.csv'"

Both directions are open: forward (``RETURN a.path`` for a given producer, or a
join the other way) lists every file an invocation produced. See *Query the
provenance graph* for the Cypher subset and *Run raw SQL* for the shared
``--format`` / ``--header`` options.
