..
   title: Query across platforms
   categories: query
   order: 40
   description: Query the current database together with other platforms' databases at read time with --extra, and tag every row by the platform it ran on.
   apis: query:graph, query:sql

Running the same experiment on several platforms leaves one single-platform
``.knit/knit.db`` per machine. ``--extra`` queries the current database
**together with** those other databases at read time, without merging any of
them: knit assembles a throwaway read-only union (a *lens*), runs the query, and
discards it. Each source database stays single-platform, and so does any bundle
made from it.

``--extra`` takes a comma-separated list; each source is a **directory** (its
``.knit/knit.db`` is used), a **database file**, or a **bundle** (a ``.tar.gz``
from ``knit bundle``, whose database is extracted to a temporary directory):

.. code-block:: console

   $ ./exp.sh query graph --extra ../run-on-pbs --exec \
       "MATCH (p:platform)-[:executed]->(j:jobs) RETURN p.id, j.id, j.state"
   $ ./exp.sh query sql --extra ../run-on-pbs/.knit/knit.db,polaris-bundle.tar.gz \
       --exec "SELECT id, state FROM jobs"

The current experiment's own database is always part of the lens; ``--extra``
adds the others. With no ``--extra``, both commands behave exactly as they do
against one database.

**The platform is a node.** Inside the lens every database contributes a
``platform`` node whose properties are that machine's fingerprint (``arch``,
``scheduler``, ``launcher``, ``profile``, ``knit_version``), and an ``executed``
edge from that platform to every row that ran on it. So the platform is one flat
hop from any command, and machine attributes filter and project like any other
column:

.. code-block:: console

   $ ./exp.sh query graph --extra ../run-on-pbs --exec \
       "MATCH (p:platform)-[:executed]->(j:jobs)-[:used_by]->(s:setups)
          WHERE p.arch = 'aarch64' RETURN p.id, j.id"

Nothing about the platform is stored in any database for this --- it is
synthesized from each database's own ``metadata`` at query time (the platform
name comes from ``knit bootstrap --platform``), so the platform node works on
existing databases and even on a single-database query.

Because the query spans one lens, aggregation, ``ORDER BY``, ``DISTINCT``, and
``count`` are correct across every platform at once --- which a shell loop that
ran the query per database and concatenated the output would get wrong:

.. code-block:: console

   $ ./exp.sh query sql --extra ../run-on-pbs --format csv --header --exec \
       "SELECT p.id AS platform, count(*) AS runs
          FROM platforms p
          JOIN __provenance__ e
            ON e.edge_type='executed' AND e.source_id=p.id
          JOIN runs r ON r.id=e.target_id
          GROUP BY p.id"

If two databases claim the **same** platform name with a different fingerprint,
knit warns and keeps both (nothing is dropped). The project name is deliberately
not checked --- a platform may be named differently per machine. All of
``--extra`` is read-only and, like the rest of ``query``, needs a bootstrapped
experiment. Shape the output with the shared ``--format`` / ``--header`` /
``--separator`` options from *Run raw SQL*; write labels as either the table or
command name as in *Query the provenance graph*.
