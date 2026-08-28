..
   title: Preview a removal with --dry-run
   categories: cleanup
   order: 20
   description: Print the exact rows, edges, and files a remove would erase without deleting anything or prompting.
   apis: remove:setup, remove:job

A cascade can reach further than expected --- removing one provider may erase
every job that used it. ``--dry-run`` computes and prints the full erase set, then
exits **without prompting and without deleting**, so you can inspect the blast
radius before committing:

.. code-block:: console

   $ ./exp.sh remove setup --type env --dry-run
   The following will be permanently erased:

     Data rows (4):
       setup    env (buildenv)       01a0...
       job                           01a0...  (state: completed)
       job      crunch               01a0...  (body row)
       artifact result.txt           01a0...

     Provenance edges (6):
       resource:srcpkg 01a0... --used_by--> setup:env 01a0...
       ...

     Directories and artifacts removed (3):
       setups/buildenv
       jobs/01a0...
       artifacts/result.txt

The report has the same three sections remove always prints --- the data rows
(setup rows show ``type (name)``), the provenance edges, and the directories and
artifact files --- plus a **Left on disk** section when a file is deliberately
kept (see *Keep the files while pruning provenance*). The report is exactly what
the confirmation prompt would show; ``--dry-run`` just stops before the prompt.

``--dry-run`` changes neither the database nor the filesystem, so it is the way to
check what a ``--type`` or ``--from-root`` selection actually pulls in before
running it for real.
