..
   title: Set the program description
   categories: commands
   order: 30
   description: Give the experiment a one-line description shown in top-level --help.
   apis: knit_set_program_description

Call ``knit_set_program_description`` once, after sourcing ``knit.sh``, to set the
line shown at the top of the experiment's ``--help``:

.. literalinclude:: /_code/commands.sh
   :language: bash
   :start-after: # START description
   :end-before: # END description
