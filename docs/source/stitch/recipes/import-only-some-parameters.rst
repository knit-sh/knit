..
   title: Import only some parameters of a set
   categories: parameters
   order: 41
   description: Import just a few of a parameter set's parameters with --only.
   apis: knit_with_parameter_set, knit_parameter_set

By default ``knit_with_parameter_set`` imports every parameter a set declares.
Pass ``--only`` with a comma-separated allow-list to import just those
parameters and leave the rest behind:

.. knit-code:: /_code/parameters.sh
   :language: bash
   :start-after: # START pset-only
   :end-before: # END pset-only

Every name in the list must exist in the set, else the call is fatal --- this
catches a typo that would otherwise silently import the whole set.
