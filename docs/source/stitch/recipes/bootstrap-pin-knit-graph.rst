..
   title: Pin the knit-graph version
   categories: bootstrap
   order: 90
   description: Provision a specific knit-graph release, or one from a custom URL.
   apis: bootstrap

``bootstrap`` provisions ``knit-graph`` (the engine behind ``knit query``) at a
pinned default version. Override the version with ``--knit-graph-version``, or
point at a specific release tarball with ``--knit-graph-url``:

.. code-block:: console

   $ ./exp.sh bootstrap --knit-graph-version 0.3.0

.. code-block:: console

   $ ./exp.sh bootstrap \
       --knit-graph-url https://example.com/knit-graph-0.3.0.tar.gz

An empty ``--knit-graph-version`` uses the pinned default; an empty
``--knit-graph-url`` derives the URL from the version.
