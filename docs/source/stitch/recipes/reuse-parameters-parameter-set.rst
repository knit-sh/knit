..
   title: Reuse parameters with a parameter set
   categories: parameters
   order: 40
   description: Declare a group of parameters once and import it into many commands.
   apis: knit_define_parameter_set, knit_with_parameter_set, knit_with_required

When several commands share the same parameters, declare them once in a named
parameter set and import the set wherever you need it. A set is opened with
``knit_define_parameter_set``, populated with the usual ``knit_with_*`` calls, and
closed with ``knit_done``:

.. literalinclude:: /_code/parameters.sh
   :language: bash
   :start-after: # START pset
   :end-before: # END pset

``knit_with_parameter_set <name>`` copies the set's parameters into the command
being registered; call it as many times as you like. A parameter from the set
that collides with one already declared on the command is a fatal error.
