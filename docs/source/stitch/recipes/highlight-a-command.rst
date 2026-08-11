..
   title: Highlight a command in --help
   categories: commands
   order: 70
   description: Bold a command's name in --help when a predicate holds.
   apis: knit_highlight_if

``knit_highlight_if <predicate>`` bolds a command's name in its parent's
``--help`` whenever the predicate returns 0 and the output is a terminal. It is
purely cosmetic: it never affects whether the command runs, its provenance, or how
``describe`` sees it.

.. literalinclude:: /_code/commands.sh
   :language: bash
   :start-after: # START highlight
   :end-before: # END highlight

The predicate is the name of a shell function that receives the command name and
returns 0 (highlight) or non-zero (plain). It is repeatable --- the name is
highlighted if any registered predicate returns 0.

This is the mechanism that bolds the builtin ``bootstrap`` command in the root
``--help`` while the experiment has not been bootstrapped yet (and leaves it plain
afterwards). The aim is to visually steer the user toward the next relevant
command.
