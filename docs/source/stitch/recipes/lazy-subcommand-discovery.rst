..
   title: Register subcommands lazily
   categories: commands
   order: 45
   description: Defer a subtree's registration until a subcommand is first reached.
   apis: knit_with_subcommand_discovery, knit_register, knit_empty

Registering a command declares its parameters, table, and callbacks up front. For
a parent with many subcommands, most runs never touch most of that subtree, so the
work is wasted. ``knit_with_subcommand_discovery`` defers it: name a *discovery
function* on the parent, and knit calls it at most once --- only when a subcommand
is actually reached (resolved on the command line, listed in the parent's
``--help``, or walked by ``describe``).

.. knit-code:: /_code/commands.sh
   :language: bash
   :start-after: # START discover
   :end-before: # END discover

The discovery function registers the parent's immediate subcommands with the
usual ``knit_register ... knit_done`` calls. It runs in the main shell (never a
subshell), so the registrations take effect, and it receives the parent's display
name as ``$1``. Keep it fast and side-effect free --- registration only ---
because it runs on the resolution and help paths.

Until the function runs, the parent exists but its subtree does not: ``widget``
appears in the top-level ``--help``, while ``widget list`` and ``widget make`` are
built only when first needed. A subcommand it registers may itself declare a
discovery function, so deeper levels stay lazy too.
