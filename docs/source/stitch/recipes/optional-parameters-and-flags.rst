..
   title: Optional parameters and flags
   categories: parameters
   order: 20
   description: Give a parameter a default, or declare a boolean flag.
   apis: knit_with_optional, knit_with_flag, knit_get_parameter

``knit_with_optional <name:type> <default> <description>`` declares a parameter
that falls back to a default when omitted. ``knit_with_flag <name> <description>``
declares a boolean flag that is either present or not:

.. knit-code:: /_code/parameters.sh
   :language: bash
   :start-after: # START optional
   :end-before: # END optional

As with ``knit_with_required``, the type annotation is mandatory (``name:string``,
``count:integer``, …). A flag is implicitly boolean, so it takes no type; it reads
back through ``knit_get_parameter`` as the string ``true`` (when the flag was
passed) or ``false`` (when it was not), so test it with ``[[ "${flag}" == "true"
]]``.
