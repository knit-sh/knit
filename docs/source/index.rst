Knit
====

Knit is a Bash framework for writing reproducible and portable HPC
(High-Performance Computing) experiments. It provides a CLI system for
registering commands with typed parameters, automatic database logging of
runs, environment/setup management, and Spack integration.

.. note::

   This documentation site is just getting started. For now only the API
   reference is available; narrative guides and tutorials will be added later.

The API is split by visibility, following Knit's underscore naming convention:
names without a leading underscore form the stable :doc:`api/public`, while
names with one or two leading underscores form the :doc:`api/private`, which may
change at any time.

.. toctree::
   :maxdepth: 2
   :caption: API Reference

   api/public
   api/private
