..
   title: Find and erase failed invocations
   categories: cleanup, recording
   order: 50
   description: Record each command's exit status in __exit_status__, query which invocations failed, and prune them all at once with remove --failed.
   apis: knit_with_table, knit_no_record_on_failure, remove

Every recorded command also records its **exit status**. A command that declares
a table (``knit_with_table``) and is not marked ``knit_no_record_on_failure``
gets a reserved ``__exit_status__`` column, written on every invocation: ``0`` on
success, the non-zero code on failure. A failed command keeps its row --- and any
output or artifact it produced before failing --- so a failure deep in a chain
stays queryable instead of vanishing:

.. knit-code:: /_code/remove.sh
   :language: bash
   :start-after: # START failing
   :end-before: # END failing

Because the row survives, you can ask the database which invocation failed, and
with which parameters --- exactly what you need to diagnose it:

.. code-block:: console

   $ ./exp.sh query sql --format column --header --exec \
       "SELECT id, code, __exit_status__ FROM boom WHERE __exit_status__ <> 0"

``__exit_status__`` is an ordinary column: it shows up in ``knit db show``,
``knit query``, and the ``knit describe`` schema view like any other. ``NULL``
(an outcome not yet known) and a row back-filled by migration are both "unknown"
and count as neither success nor failure.

To clean up, ``remove --failed`` selects **every** invocation with a non-zero
exit status at once, across every table that carries the column:

.. code-block:: console

   $ ./exp.sh remove --failed --dry-run              # preview the failed set
   $ ./exp.sh remove --failed --yes                  # erase the failed rows
   $ ./exp.sh remove --failed --from-root --yes      # erase the jobs that contain them too

``--failed`` uses the same closure and guards as every ``remove`` subcommand. On
its own it erases the failed rows, but a **failed callee whose caller is kept** is
refused --- a failed run inside a job that stays, for instance --- with a hint to
pass ``--from-root``, which widens to the whole lineage so the enclosing job is
erased too (see *Erase a whole lineage with --from-root*). There is no per-code
selector: ``--failed`` means any non-zero code. To remove by a specific code,
write the ``SELECT`` yourself and pass the ids to ``remove <kind> --id``.

A command marked ``knit_no_record_on_failure`` is the exception: it records no row
on failure, so it has no ``__exit_status__`` column and never appears in the
``--failed`` set.
