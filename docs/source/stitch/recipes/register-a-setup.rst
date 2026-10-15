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

A setup can lean on an **environment manager** for that software: a plugin that
provisions and activates an environment for the setup, so the body does not build
every dependency by hand. Spack is the first such manager --- import it with
``knit_import spack`` --- and a setup names its needs through the manager's
directive, generically ``knit_with_<manager>_env`` (for Spack,
``knit_with_spack_env`` or the ``knit_with_spack_specs`` shorthand). The setup
below asks Spack for ``cmake`` and ``libpng``, then builds and installs the
program into ``KNIT_SETUP_PREFIX``; see the *Spack* recipes for the manager
details.

.. knit-code:: /_code/julia_setup.sh
   :language: bash
   :start-after: # START setup
   :end-before: # END setup
