..
   title: Provide the default setup
   categories: setup
   order: 40
   description: Understand the builtin default setup that jobs adopt, and how to opt out.
   apis: knit_without_setup, knit_with_setup, knit_register_job

Bootstrap auto-instantiates a builtin ``default`` setup that carries only the
platform activation (the profile's modules and environment, if any). A job that
declares neither ``knit_with_setup`` nor ``knit_without_setup`` runs inside this
default setup automatically, so it inherits the platform environment with no
boilerplate:

.. literalinclude:: /_code/default_setup.sh
   :language: bash
   :start-after: # START adopt
   :end-before: # END adopt

To run a job with no setup at all --- no setup directory and no platform
activation --- opt out with ``knit_without_setup`` (mutually exclusive with
``knit_with_setup``):

.. literalinclude:: /_code/default_setup.sh
   :language: bash
   :start-after: # START optout
   :end-before: # END optout

The default setup is a setup type like any other, so a command can also require
it explicitly by name:

.. literalinclude:: /_code/default_setup.sh
   :language: bash
   :start-after: # START require-default
   :end-before: # END require-default

Only jobs adopt the default setup implicitly; a plain command is setup-less
unless it declares ``knit_with_setup``, so on a plain command
``knit_without_setup`` is a no-op. The default setup is materialized at bootstrap,
but you can (re)build a named copy of any setup type with the ``setup``
dispatcher:

.. code-block:: console

   $ ./exp.sh setup --name default -- default
