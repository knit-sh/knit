..
   title: Opt in/out of the provenance graph
   categories: provenance
   order: 20
   description: Force a command in or out of the provenance graph with knit_with_provenance and knit_without_provenance.
   apis: knit_with_provenance, knit_without_provenance

Alongside data rows, knit records a **provenance graph**: each participating
invocation is a node, and calling one command from another records a "call" edge,
so a query can trace which run produced which result. Whether a command
participates is orthogonal to whether it records a table (see *Record invocations
in a table*) --- a command can do either, both, or neither.

By default participation follows visibility: visible commands participate; hidden
commands (``knit_hidden``, e.g. internal workers) are transparent. Override that
default explicitly.

Use ``knit_without_provenance`` to keep a visible command out of the graph. A
read-only fan-in command that only reads back existing rows is the typical case
--- it should not add call edges of its own:

.. literalinclude:: /_code/julia_aggregate.sh
   :language: bash
   :start-after: # START aggregate
   :end-before: # END aggregate

Use ``knit_with_provenance`` for the opposite: force a command *into* the graph
even when it would otherwise be transparent (for example a hidden command you
still want to see as a node).

Either mark propagates to unmarked lexical descendants, so marking a parent
command governs its whole colon-nested subtree unless a child overrides it. A
transparent command is skipped when a command it invokes resolves its parent: the
callee links to the nearest participating ancestor instead.
