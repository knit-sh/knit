..
   title: Forward parameters to another command
   categories: parameters
   order: 40
   description: Pass parameters and flags on to another command without emitting dangling options.
   apis: knit_forward_parameter_as, knit_forward_flag_as, knit_get_parameter_with_default, knit_get_parameter

A command body often forwards some of its parameters to a downstream command or
program. The naive ``--dim "$(knit_get_parameter size "$@")"`` breaks when the
parameter is absent: ``knit_get_parameter`` prints an empty string, leaving a
dangling ``--dim`` with no value. The forwarding helpers avoid this by printing
whole tokens (or nothing) that the shell splits when used **unquoted**:

.. knit-code:: /_code/parameters.sh
   :language: bash
   :start-after: # START forward
   :end-before: # END forward

- ``knit_forward_parameter_as <option> <name> "$@"`` prints ``<option> <value>``
  when the parameter is present and nothing when it is absent, so the option is
  dropped rather than left empty.
- ``knit_forward_flag_as <if-true> <if-false> <flag> "$@"`` chooses its text from
  a flag's value. Supplying both texts lets a flag be forwarded under its
  negation — ``knit_forward_flag_as "" "--banner" "quiet" "$@"`` emits
  ``--banner`` only when ``--quiet`` was not set.
- ``knit_get_parameter_with_default <name> <default> "$@"`` prints a fallback for
  an absent parameter, which ``knit_get_parameter`` cannot distinguish from a
  parameter set to an empty value.

.. note::

   The output is meant to be used unquoted so the shell splits it into tokens, so
   a forwarded value containing whitespace is not supported — the same limitation
   as any unquoted command-substitution forwarding.
