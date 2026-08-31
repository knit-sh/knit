..
   title: Define and use an enum
   categories: types
   order: 20
   description: Restrict a parameter to a fixed set of values with a custom enum type.
   apis: knit_enum, knit_enum_values, knit_with_required

To restrict a parameter to a fixed set of values, define an enum with
``knit_enum <name> <value>...`` and then use its name as a parameter type.
Knit validates the value against the allowed set for you, exactly as it does for
the built-in types.

.. knit-code:: /_code/types.sh
   :language: bash
   :start-after: # START enum
   :end-before: # END enum

Here ``to:format`` reads as "a parameter named ``to`` of the enum type
``format``". Calling ``convert --to gif`` fails with *Parameter --to of
"convert" expects one of: png, jpeg, webp (got "gif")* — the error lists the
accepted values in the order they were defined. ``knit_enum_values <name>``
prints an enum's values (one per line, or joined by a separator when you pass
one, as in the parameter description above), which is handy for building help
text or looping over the choices.
