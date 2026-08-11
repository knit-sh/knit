..
   title: Depend on a setup
   categories: setup
   order: 20
   description: Bind a command to a setup so it runs inside that software environment.
   apis: knit_with_setup

Declare ``knit_with_setup`` right after registering a command (or job) to bind it
to a setup. Before the command's body runs, Knit activates that setup's
environment --- its ``PATH``, libraries, and any Spack packages --- so the
command finds the software the setup installed.

.. literalinclude:: /_code/julia_setup.sh
   :language: bash
   :start-after: # START depends
   :end-before: # END depends
