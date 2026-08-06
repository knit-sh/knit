Knit
====

Knit is a Bash framework for writing reproducible and portable HPC
(High-Performance Computing) experiments. It provides a CLI system for
registering commands with typed parameters, automatic database logging of
runs, environment/setup management, and Spack integration.

New to Knit? The :doc:`quickstart` writes and runs a one-command experiment in a
few minutes.

The API is split by visibility, following Knit's underscore naming convention:
names without a leading underscore form the stable :doc:`api/public`, while
names with one or two leading underscores form the :doc:`api/private`, which may
change at any time.

.. toctree::
   :maxdepth: 2
   :caption: Guides

   quickstart

.. toctree::
   :maxdepth: 2
   :caption: API Reference

   api/public
   api/private
