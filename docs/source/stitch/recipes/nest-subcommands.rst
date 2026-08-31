..
   title: Nest subcommands
   categories: commands
   order: 40
   description: Group commands under a parent using colon-nested names.
   apis: knit_register, knit_empty, knit_with_subcommand_title

Colons in a command name nest it under a parent, so ``say:hello`` is invoked as
``say hello``. Register the parent with ``knit_empty`` (it only groups its
children) and, optionally, rename the section they appear under in ``--help`` with
``knit_with_subcommand_title``:

.. knit-code:: /_code/commands.sh
   :language: bash
   :start-after: # START nest
   :end-before: # END nest

Nesting can go deeper (``say:hello:loudly`` → ``say hello loudly``); each parent
level is registered the same way.
