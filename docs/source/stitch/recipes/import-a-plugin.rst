..
   title: Import a plugin
   categories: plugins
   order: 10
   description: Add a plugin to an experiment with knit_import, pinned to a ref.
   apis: knit_import

``knit_import`` fetches a plugin from a git host, pins the exact commit, verifies
its checksum, and sources it, so the plugin's commands and decorators become
available. Call it at the top of the experiment, after ``source knit.sh`` and
before using what the plugin provides:

.. knit-code:: /_code/plugin_use.sh
   :language: bash
   :start-after: # START import
   :end-before: # END import

The short form expands to ``github.com/knit-sh/knit-<name>``. A mutable ref such
as a branch resolves to a commit on the first bootstrap and is frozen in
``knit-plugins.lock``, so a later run and a fresh checkout use the same code.
Bootstrap also records each plugin in the ``plugins`` table and materializes its
pinned tree under ``.knit/plugins/`` for a self-contained experiment directory.
