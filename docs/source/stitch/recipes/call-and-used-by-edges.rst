..
   title: Understand call and used_by edges
   categories: provenance
   order: 10
   description: The __provenance__ table links recorded rows with directed call and used_by edges, so a query can trace what produced what.
   apis: knit_with_setup

Each command records its own rows in its own table (see *Record invocations in a
table*). The **provenance graph** is what links those rows across tables: a
single ``__provenance__`` table whose every row is one directed edge between two
invocations, written as ``source --edge_type--> target``. An edge stores the
``(id, name)`` pair of its source and target --- the ``id`` joins to a row, and
the ``name`` identifies which table that row lives in --- so a query can hop from
a row in one table to a related row in another.

There are two kinds of edge:

- **call** --- the source invoked the target. Every time a participating command
  runs another command, knit records a ``call`` edge from caller to callee, and
  stamps it with the call's ``start_time`` and ``end_time``. This is how a job's
  row links to the ``knit run`` rows it launched, and those to the app rows the
  run recorded. A ``call`` edge may also carry an ``alias`` naming the call site
  (see *Distinguish repeated calls*).
- **used_by** --- the target references a setup that an earlier invocation built.
  When a job (or other command) declares ``knit_with_setup`` (see *Depend on a
  setup*), knit records a ``used_by`` edge from the **setup** (the source, the
  antecedent) to the invocation that uses it (the target). It has no duration, so
  its timestamps are ``NULL``.

The direction is consistent: the source is always the antecedent (the caller, or
the setup that was built first) and the target the dependent (the callee, or the
consumer). Which invocations become nodes is governed by participation --- see
*Opt in/out of the provenance graph* --- and the edges themselves are queried
with ``knit query graph``.
