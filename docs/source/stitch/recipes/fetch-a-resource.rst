..
   title: Fetch a resource instance
   categories: resources
   order: 20
   description: Acquire a named instance of a resource type with the knit fetch dispatcher.
   apis: fetch

``knit fetch`` acquires a named *instance* of a registered resource type. Like
``knit setup``, it is a dispatcher: options before ``--`` configure the fetch, and
everything after ``--`` selects the resource type and its own arguments.

.. code-block:: console

   $ ./exp.sh fetch --name sample -- dataset --path ./data
   /path/to/experiment/resources/sample

The instance lands at ``resources/<name>`` and is recorded in the type's table for
provenance. Fetching is idempotent by name: re-fetching ``sample`` from the same
source does nothing, while a different source under the same name is refused. A
downloaded or copied instance is made read-only so a shared input cannot be
mutated. ``knit fetch`` prints the instance path on stdout (logging is on stderr),
but commands normally consume a resource by name (see *Consume a resource in a
command*).
