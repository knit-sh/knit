..
   title: Positional arguments
   categories: parameters
   order: 15
   description: Why Knit has no positional parameters, and what to write instead.
   apis: knit_with_required

Knit deliberately has **no positional parameters**: every value is passed by name
(``--width 3``), never by position (``box 3 4``). This is a design choice, not a
limitation — forcing callers to name every argument keeps experiment scripts
explicit and self-documenting, and rules out the classic positional mistakes of
swapping two arguments or silently dropping one.

A bare token where a command name would go is treated as a subcommand, so
``box 3 4`` fails with an *"Unknown command"* error rather than being quietly
misread as ``--width 3 --height 4``. Write ``box --width 3 --height 4`` instead:
the order no longer matters, and a forgotten argument is reported as a missing
required parameter rather than shifting every value by one.
