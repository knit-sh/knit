..
   title: Discover the schema
   categories: query
   order: 10
   description: List the database's tables and columns, or validate a reference, with query catalog before writing a query.
   apis: query:catalog

Before writing a query you need to know what is there. ``query catalog`` lists
every table in the experiment's database and its columns --- the same schema both
``query graph`` and ``query sql`` see:

.. code-block:: console

   $ ./exp.sh query catalog
   table jobs (command: submit)
     column id (TEXT)
     column state (TEXT)
     column hostnames (TEXT)
     column nodes (INTEGER)
   table runs
     column id (TEXT)
     column app (TEXT)
     column procs (INTEGER)
   table metadata
     column key (TEXT)
     column value (TEXT)
   table __provenance__
     column source_id (TEXT)
     column target_id (TEXT)
     column edge_type (TEXT)

Each column is annotated with its SQL storage type (``TEXT``/``INTEGER``/
``REAL``), and every table that a command records under a **different** name is
annotated with its owning command --- here ``jobs`` is written by ``submit``, so
a query may label the node either way (see *Query the provenance graph*).

Pass a reference with ``--ref`` to narrow the listing to one table, or to
validate a single ``TABLE.COLUMN``:

.. code-block:: console

   $ ./exp.sh query catalog --ref jobs
   $ ./exp.sh query catalog --ref jobs.procs

A ``TABLE.COLUMN`` reference exits non-zero when the table or column does not
exist, which makes ``query catalog --ref`` a cheap way to check a column name
from a script before building a larger query. ``query catalog`` is read-only and,
like the rest of ``query``, needs a bootstrapped experiment.
