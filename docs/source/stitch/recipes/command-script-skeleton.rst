..
   title: The experiment script skeleton
   categories: commands
   order: 10
   description: The minimal top-and-tail every Knit experiment script needs.
   apis: knit, KNIT_SCRIPT_NAME

A Knit experiment is an ordinary Bash script that ``source``\ s ``knit.sh`` near
the top and hands control to Knit's dispatcher at the very bottom:

.. literalinclude:: /_code/commands.sh
   :language: bash
   :start-after: # START skeleton
   :end-before: # END skeleton

Everything between those two lines registers commands. The final line dispatches
the script's arguments to whichever command the user named:

.. literalinclude:: /_code/commands.sh
   :language: bash
   :start-after: # START entry
   :end-before: # END entry

Inside any command you can read ``KNIT_SCRIPT_NAME`` --- the base name of the
script that sourced ``knit.sh`` --- to build messages that name the experiment
(for example ``"Run ./${KNIT_SCRIPT_NAME} bootstrap first."``).
