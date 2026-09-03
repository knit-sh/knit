..
   title: Walk an artifact's full lineage
   categories: query, artifacts
   order: 75
   description: Walk producer --produced--> artifact --used_by--> consumer in one query by joining the two provenance edges on the artifact's row.
   apis: query:graph, query:sql, knit_with_input_artifact, knit_with_output_artifact

An artifact sits between the command that made it and the commands that read it.
The producer leaves a ``produced`` edge into the artifact's row (see *Trace an
artifact back to its producer*); each consumer leaves a ``used_by`` edge out of
it (see *Consume an artifact by kind*). Because both edges meet at the same
``artifacts`` node, one query walks the whole chain ``producer --produced-->
artifact --used_by--> consumer``.

With ``query graph`` the chain is a single Cypher path through the artifact node,
keyed on its artifacts-relative ``path``:

.. code-block:: console

   $ ./exp.sh query graph --format column --header --exec \
       "MATCH (p)-[:produced]->(a:artifacts)-[:used_by]->(c)
          WHERE a.path = 'table.csv'
          RETURN p.source_name, a.kind, c.target_name"

The producing and consuming nodes need no label --- read them off the edges, so
the same query works whatever commands sit at the ends. To list *everything* that
read a given artifact, keep only the ``used_by`` half (``RETURN c.target_name``);
to list every artifact a command consumed, match the ``used_by`` edge into it.

The same walk in ``query sql`` joins the two ``__provenance__`` edges to the
``artifacts`` row on the artifact id:

.. code-block:: console

   $ ./exp.sh query sql --format column --header --exec \
       "SELECT pr.source_name AS producer, ub.target_name AS consumer
          FROM artifacts a
          JOIN __provenance__ pr ON pr.target_id = a.id AND pr.edge_type = 'produced'
          JOIN __provenance__ ub ON ub.source_id = a.id AND ub.edge_type = 'used_by'
         WHERE a.path = 'table.csv'"

See *Query the provenance graph* for the Cypher subset and *Run raw SQL* for the
shared ``--format`` / ``--header`` options.
