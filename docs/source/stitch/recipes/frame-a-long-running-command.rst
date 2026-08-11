..
   title: Frame a long-running command
   categories: logging
   description: Pipe a noisy command's output into knit_framed to keep it inside a fixed scrolling box, with safe non-TTY passthrough.
   apis: knit_framed
   order: 20

A build or install can spew hundreds of lines. Pipe its output into
``knit_framed`` to confine that noise to a fixed, scrolling box with a title,
instead of letting it flood the terminal:

.. literalinclude:: /_code/logging.sh
   :language: bash
   :start-after: # START framed
   :end-before: # END framed

The two leading positional arguments are the frame's ``height`` and ``width``
(both default to the terminal size; pass ``-1`` for either to keep the default).
Useful named options follow:

- ``--title <text>`` centers a label on the top border.
- ``--cleanup`` erases the frame once the command finishes, leaving no trace on
  screen.
- ``--log-level <level>`` only draws the frame when ``KNIT_LOG_LEVEL`` is at or
  below that level; otherwise the input is drained silently. Use it to hide
  verbose output unless someone is debugging.
- ``--frame-color`` / ``--text-color`` (and their ``--*-bg-color`` variants) tint
  the border and text.

``knit_framed`` only draws when stdout is a **terminal**. When it is not --- a
redirect to a log file, a pipe, a CI run --- stdin is forwarded to stdout
unchanged, so framing decorates an interactive session but never corrupts
captured or piped output.
