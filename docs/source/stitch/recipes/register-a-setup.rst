..
   title: Register a setup
   categories: setup
   order: 10
   description: Register a setup that builds and installs software into its own prefix.
   apis: knit_register_setup, knit_with_spack_specs, KNIT_SETUP_PREFIX

Use ``knit_register_setup`` to declare a *setup*: a reproducible software
environment that Knit builds once and reuses. The setup function installs
everything it needs under ``KNIT_SETUP_PREFIX`` --- the private directory Knit
creates for it --- so commands that depend on the setup find the software on
their ``PATH``.

.. knit-code:: /_code/julia_setup.sh
   :language: bash
   :start-after: # START setup
   :end-before: # END setup
