..
   title: Exclude parameters when importing a set
   categories: parameters
   order: 42
   description: Import a parameter set minus a few parameters, freeing those names to re-declare.
   apis: knit_with_parameter_set, knit_parameter_set, knit_with_optional

Pass ``--exclude`` with a comma-separated deny-list to import every parameter of
a set but the named ones. Excluding a name also frees it, so the command can
declare it itself with a different kind or default --- here a parameter that is
required in the set becomes optional on this command:

.. knit-code:: /_code/parameters.sh
   :language: bash
   :start-after: # START pset-exclude
   :end-before: # END pset-exclude

Every excluded name must exist in the set, else the call is fatal.
``--exclude`` and ``--only`` are mutually exclusive.
