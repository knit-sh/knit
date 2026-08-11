..
   title: Record invocations in a table
   categories: recording
   order: 10
   description: Declare a table with knit_with_table so knit records one row per invocation, with a column per parameter and output.
   apis: knit_with_table

Add ``knit_with_table`` between ``knit_register`` and ``knit_done`` and knit
records **one row per invocation** of the command in a SQLite table:

.. literalinclude:: /_code/quickstart.sh
   :language: bash
   :start-after: # START add
   :end-before: # END add

The table's columns are derived from the command's declaration: an ``id`` (a
uuid) first, then its required parameters, optional parameters, flags, and
outputs --- here ``id``, ``x``, ``y``, and ``total``. The schema is created (and
migrated if the declaration later changes) automatically when the experiment
loads, so you never write ``CREATE TABLE`` yourself.

The table name defaults to the command's name (colon-joined for a subcommand,
e.g. ``foo:bar``); pass an explicit name to override it, as in
``knit_with_table "my_runs"``. Two commands cannot claim the same table.

The row is written automatically after the body returns: knit fills the
parameter columns from the invocation's arguments and the output columns from
whatever the body emitted with ``knit_output`` (see *Emit outputs from a
command*). Recording needs a bootstrapped experiment --- before ``bootstrap`` it
is a no-op --- and each invocation is recorded once. Read the rows back later
with ``knit query sql``; invoking ``add --x 2 --y 3`` leaves a row whose ``x``,
``y``, and ``total`` are ``2``, ``3``, and ``5``.
