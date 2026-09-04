..
   title: Fan out a variadic output
   categories: artifacts
   order: 55
   description: Declare a *-quantified output artifact and bind the same name many times, so one command produces a whole collection.
   apis: knit_with_output_artifact, knit_artifact_dir, knit_artifact

A scalar artifact binds once. Add a ``*`` (zero or more) or ``+`` (one or more)
to the kind and the name becomes a **collection**: the body may bind it any
number of times, and each binding is its own ``artifacts`` row with its own
``produced`` edge. Use it when one run scatters a whole set of files --- shards,
frames, per-seed outputs --- that you do not know the count of up front:

.. knit-code:: /_code/variadic_artifacts.sh
   :language: bash
   :start-after: # START fanout
   :end-before: # END fanout

The quantifier is the only difference from a scalar declaration. ``*`` accepts an
empty fan-out (a run that produced nothing is not an error); ``+`` requires at
least one binding and is fatal after the body if none was made, so it states *at
least one of these must exist*. The write-once rule is unchanged: each member
still needs a distinct artifacts-relative path (here ``shard-${i}.csv``), so a
loop that reuses one path is rejected. Every member is recorded exactly as a
scalar artifact is --- same ``path``/``name``/``kind``/``checksum`` columns, same
``produced`` edge --- so the collection needs no special handling to trace,
remove, or query; it is simply several artifact rows sharing one declared name.
Consume the whole set at once with a variadic input (see *Consume many artifacts
with a glob*).
