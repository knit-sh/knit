..
   title: Describe the command tree
   categories: introspection
   description: Dump every declared command, its parameters, and its outputs with knit describe, in a human or machine-readable format.
   apis: describe
   order: 10

``describe`` prints the whole command tree --- every command, its parameters
(name, type, default, description), and its outputs --- reading straight from the
registration tables. It needs no database, so it works on a fresh checkout
**before** ``bootstrap``:

.. code-block:: console

   $ ./exp.sh describe

The default format is a colorized, human-readable listing. Switch to a
machine-readable one with ``--format`` when a tool needs to consume the tree:

.. code-block:: console

   $ ./exp.sh describe --format json
   $ ./exp.sh describe --format json --compact
   $ ./exp.sh describe --format yaml
   $ ./exp.sh describe --format markdown

``--compact`` collapses the JSON onto a single line with no insignificant
whitespace (it applies only to ``--format json``); the pretty form is the
default. Every format carries the same header --- the knit version, the
experiment script name, and a ``format_version`` --- so consumers can pin to a
shape.

A few flags narrow or widen what is dumped:

- ``--only a,b:c`` restricts the output to named commands (colon form for
  subcommands); add ``--recursive`` to also include their subcommands.
- ``--exclude-builtins`` drops the framework's own commands, leaving just what
  your script declares --- handy for documenting an experiment's public surface.
- ``--no-input-params`` / ``--no-output-params`` trim the parameter or output
  sections; ``--include-hidden`` adds hidden and framework-private commands;
  ``--include-implementation`` appends each user command's function body.
- ``--output <file>`` writes to a file instead of stdout (and disables the
  default format's auto-color, since the destination is not a terminal);
  ``--no-color`` disables color for the default format on a terminal.

For a single command's parameters and usage, ``<command> --help`` is often
quicker; ``describe`` is for taking in --- or exporting --- the entire tree at
once.
