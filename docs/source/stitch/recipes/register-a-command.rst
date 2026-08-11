..
   title: Register a command
   categories: commands
   order: 20
   description: Declare a command with knit_register, a body function, and knit_done.
   apis: knit_register, knit_done, knit_empty

Every command is declared with ``knit_register <name> <function> <description>``,
followed by any parameter declarations, and closed with ``knit_done``. The named
function is the command's body:

.. literalinclude:: /_code/commands.sh
   :language: bash
   :start-after: # START register
   :end-before: # END register

Use ``knit_empty`` as the body when a command does nothing yet (a stub) or when
it exists only to group subcommands under it.
