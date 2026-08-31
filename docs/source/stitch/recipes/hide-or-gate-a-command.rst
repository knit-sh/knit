..
   title: Hide or gate a command
   categories: commands
   order: 60
   description: Control a command's visibility in --help and whether it may run.
   apis: knit_hidden, knit_hidden_if, knit_usable_if, knit_usable_before_bootstrap

``knit_hidden`` removes a command from ``--help`` while leaving it fully
invokable; ``knit_usable_if`` blocks a command from running unless a predicate
holds, showing its description as the error otherwise:

.. knit-code:: /_code/commands.sh
   :language: bash
   :start-after: # START gate
   :end-before: # END gate

Related decorators, all applied between ``knit_register`` and ``knit_done``:

- ``knit_hidden_if <predicate>`` --- hide from ``--help`` only when the predicate
  returns 0 (dynamic; the command stays invokable). Mutually exclusive with
  ``knit_hidden``.
- ``knit_usable_before_bootstrap`` --- allow the command to run (and appear in
  ``--help``) on a fresh checkout before ``bootstrap`` has created ``.knit/``.
  Such a command may not declare a table or a ``--when`` constraint.

Each predicate is the name of a shell function that receives the command name and
returns 0 or non-zero.
