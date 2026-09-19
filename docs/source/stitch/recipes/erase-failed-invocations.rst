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

Scope it to one kind
^^^^^^^^^^^^^^^^^^^^^

``--failed`` is also a filter on each row-kind subcommand, where it **composes**
with the selector. On its own it means every failed one of that kind; with a
selector it narrows to the failed rows the selector chose (an AND):

.. code-block:: console

   $ ./exp.sh remove command --failed                 # every failed plain command
   $ ./exp.sh remove setup --failed --type buildenv   # failed buildenv setups only
   $ ./exp.sh remove run --failed --from-root --yes    # failed runs and their jobs

So failures are prunable one kind at a time instead of all at once. A failed
``setup`` / ``resource`` / ``command`` is a row of that kind with a non-zero
status; a failed ``job`` or ``run`` is one whose **body** returned non-zero (a job
that tolerated a failed run inside it did itself succeed, so it is not a failed
job --- reach the run with ``remove run --failed``). A selector that matches
nothing is still an error, but a selection that simply contains no failures is a
quiet "nothing to erase". ``remove artifact`` has no ``--failed``: an artifact is
produced, not invoked, so it has no exit status.

A command marked ``knit_no_record_on_failure`` is the exception: it records no row
on failure, so it has no ``__exit_status__`` column and never appears in the
``--failed`` set.
