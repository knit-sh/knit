..
   title: Declare a setup's environment
   categories: setup
   order: 18
   description: Declare environment changes a setup passes to dependent commands, composably.
   apis: knit_setup_env_set, knit_setup_env_prepend, knit_setup_env_append, knit_setup_env_unset, knit_setup_activate_line

A setup does not export its environment by taking a snapshot of the build shell.
Instead the setup body *declares* each environment change, and Knit records it as
a line in the setup's ``.activate.sh``. Every command that depends on the setup
sources that file, so it runs with exactly what the setup declared --- nothing
more.

Each function changes the build shell now **and** records a composable line:

- ``knit_setup_env_set VAR value`` --- set a variable.
- ``knit_setup_env_prepend VAR entry`` / ``knit_setup_env_append VAR entry`` ---
  add one entry to a colon-separated search path such as ``PATH``. The recorded
  line keeps the ``${VAR}`` reference literal, so a dependent command extends its
  **own** ``PATH`` instead of overwriting it.
- ``knit_setup_env_unset VAR`` --- remove a variable.
- ``knit_setup_activate_line 'line'`` --- record a verbatim line (for example a
  ``module load``). It runs in declaration order, so it can build on a variable
  set above it.

.. knit-code:: /_code/setup_activation.sh
   :language: bash
   :start-after: # START setup
   :end-before: # END setup

A dependent command reads the composed environment with no extra work:

.. knit-code:: /_code/setup_activation.sh
   :language: bash
   :start-after: # START job
   :end-before: # END job
