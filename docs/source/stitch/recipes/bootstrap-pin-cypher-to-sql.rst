..
   title: Pin the knit-cypher-to-sql version
   categories: bootstrap
   order: 90
   description: Provision a specific knit-cypher-to-sql release, or one from a custom URL.
   apis: bootstrap

``bootstrap`` provisions ``knit-cypher-to-sql`` (the transpiler behind ``knit
query``) at a pinned default version. Override the version with
``--knit-cypher-to-sql-version``, or point at a specific release tarball with
``--knit-cypher-to-sql-url``:

.. code-block:: console

   $ ./exp.sh bootstrap --knit-cypher-to-sql-version 0.1.0

.. code-block:: console

   $ ./exp.sh bootstrap \
       --knit-cypher-to-sql-url https://example.com/knit-cypher-to-sql-0.1.0.tar.gz

An empty ``--knit-cypher-to-sql-version`` uses the pinned default; an empty
``--knit-cypher-to-sql-url`` derives the URL from the version.
