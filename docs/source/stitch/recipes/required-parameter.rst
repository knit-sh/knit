..
   title: Add a required parameter
   categories: parameters
   order: 10
   description: Declare a parameter the caller must supply and read it in the body.
   apis: knit_with_required, knit_get_parameter

``knit_with_required <name:type> <description>``, placed between
``knit_register`` and ``knit_done``, declares a parameter the caller must supply
as ``--name value``. The body reads it back with ``knit_get_parameter``:

.. knit-code:: /_code/parameters.sh
   :language: bash
   :start-after: # START required
   :end-before: # END required

The type annotation is **required** — there is no default type, so ``name`` alone
is rejected and you must write ``name:string``, ``width:integer``, and so on (see
the Types category for the full list). ``knit_get_parameter <name> "$@"`` prints
the value, accepting both ``--name value`` and ``--name=value``.
