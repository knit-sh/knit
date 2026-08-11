..
   title: Distinguish repeated calls
   categories: provenance
   order: 30
   description: Name a call with knit_as so repeated invocations of the same command can be told apart in a provenance query.
   apis: knit_as

When one command invokes another more than once, each call is a separate edge in
the provenance graph --- but by default the edges look alike, so a later query
cannot tell one call apart from another. ``knit_as`` names a single call: it
records an alias on that call's provenance edge, then runs the command:

.. code-block:: bash

   knit_as fast run --procs 8 -- mcrank
   knit_as slow run --procs 1 -- mcrank

Used as ``knit_as <alias> <cmd> …``, it is equivalent to ``knit <cmd> …`` except
that the delegated invocation's call edge carries ``<alias>``. A query can then
address each call independently --- "the ``fast`` run" versus "the ``slow`` run"
--- instead of seeing two indistinguishable edges. Without ``knit_as`` a call
edge's alias is ``NULL``.

The alias is one-shot: it lands only on the directly named call's edge, never on
the nested edges that call's own body records. It is validated at the call site
--- it must be non-empty, must not be a registered table name (which would
collide with a node label in a query), and must not already have been used within
the current invocation (two edges sharing an alias would be indistinguishable).
