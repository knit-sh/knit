..
   title: Validate args in a plain function
   categories: parameters
   order: 60
   description: Reject unexpected arguments in a helper that is not a registered command.
   apis: knit_check_arguments, knit_get_parameter

Registered commands validate their arguments automatically, but a plain helper
that parses its own ``"$@"`` does not. ``knit_check_arguments <options> <flags>
"$@"`` gives such a helper the same check: the first list names options that take
a value, the second names flags, and it returns 1 on the first unexpected
argument (logging an error attributed to the caller):

.. literalinclude:: /_code/parameters.sh
   :language: bash
   :start-after: # START check-args
   :end-before: # END check-args

Names use hyphens or underscores interchangeably, and everything from a literal
``--`` onwards is treated as extra and left unchecked.
