..
   title: Author a decorator
   categories: plugins
   order: 30
   description: Build a decorator from the public registration surface.
   apis: knit_run_before, knit_add_command_note, knit_command_set_marker, knit_command_has_marker, knit_current_command

A *decorator* is a function that changes the command currently being registered,
the way the built-in ``knit_with_*`` decorators do. It is built from the public
registration surface: ``knit_run_before`` installs a callback that runs before
the command body, ``knit_add_command_note`` adds a line to the command's
``--help`` requirements, and the per-command markers
(``knit_command_set_marker`` / ``knit_command_has_marker``) let the decorator
reject a second use of itself:

.. knit-code:: /_code/plugin_author.sh
   :language: bash
   :start-after: # START decorator
   :end-before: # END decorator

Apply it in the registration block between ``knit_register`` and ``knit_done``,
like any ``knit_with_*`` call.
