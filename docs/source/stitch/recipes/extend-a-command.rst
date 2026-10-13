..
   title: Extend a command
   categories: plugins
   order: 50
   description: Reopen a registered command to add options or hooks with knit_extend.
   apis: knit_extend, knit_ensure_subcommand_exists

``knit_extend`` reopens the registration of a command that is already closed, so
the ordinary decorators apply to it again. It works on any registered entity ---
a command, setup, job, app, or enum --- including a core Knit command. A plugin
uses it to add an option to, or hook the body of, a command it did not define:

.. knit-code:: /_code/plugin_author.sh
   :language: bash
   :start-after: # START extend
   :end-before: # END extend

``knit_ensure_subcommand_exists`` first runs the lazy discovery so the target is
registered before ``knit_extend`` reopens it. Between ``knit_extend`` and
``knit_done`` the decorators *append* to the command's existing options,
callbacks, and table columns; the re-run of its done callbacks is idempotent.
