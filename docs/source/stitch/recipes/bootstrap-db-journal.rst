..
   title: Avoid "database is locked" with WAL
   categories: bootstrap
   order: 46
   description: Choose the database journal mode; use WAL when many processes on one host read and write at once.
   apis: bootstrap

Under heavy concurrency --- many jobs finishing at once, or a pilot being
cancelled while its workers and the login side all touch the database --- a
*read* can fail with ``Error: database is locked``. Knit serializes writers with
a lock, but in the default rollback-journal mode a reader is blocked while a
writer holds the database, and under a burst of writers that wait can exceed the
busy timeout.

SQLite's write-ahead log (WAL) mode fixes this: a reader never blocks on a
writer, and a writer never blocks readers. Turn it on at bootstrap:

.. code-block:: console

   $ ./exp.sh bootstrap --db-journal wal

``--db-journal`` has two values:

- ``delete`` (default): SQLite's rollback journal. Works everywhere, including
  across nodes and on network filesystems.
- ``wal``: the write-ahead log. Readers never block on a writer.

.. warning::

   **WAL works only on a single host.** It coordinates readers and the writer
   through a shared-memory file, so every process that touches the database must
   run on the same machine. Use ``wal`` for single-host contention --- a login
   node, a single-node pilot, a busy CI runner. Never use it across nodes or on a
   network filesystem; keep ``delete`` there.

``--db-journal`` is independent of ``--db-lock`` (which chooses how *writers*
serialize), and the two compose:

================================  ===================================
Where the experiment runs         Bootstrap with
================================  ===================================
One host, heavy read/write        ``--db-journal wal``
Across nodes / network FS         ``--db-journal delete`` (default)
Filesystem without ``flock``      add ``--db-lock mkdir``
================================  ===================================

You set the mode once, at bootstrap. To change it later, run ``bootstrap`` again
with a different ``--db-journal``; Knit converts the database in place (and a
``knit bundle`` always ships a portable rollback-journal copy, so switching to
``wal`` never makes a bundle unreadable elsewhere).
