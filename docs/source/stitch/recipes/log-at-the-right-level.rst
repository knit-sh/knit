..
   title: Log at the right level
   categories: logging
   description: Narrate a command with knit_trace/debug/info/warning/error/critical and control verbosity with KNIT_LOG_LEVEL or knit_log_set_level.
   apis: knit_trace, knit_debug, knit_info, knit_warning, knit_error, knit_critical, knit_fatal, knit_log_set_level, KNIT_LOG_LEVEL
   order: 10

Knit gives you one logging function per severity --- ``knit_trace``,
``knit_debug``, ``knit_info``, ``knit_warning``, ``knit_error``, and
``knit_critical`` --- so you can narrate a command and let the reader choose how
much to see. Each takes ``printf``-style arguments, prefixes the line with
``[knit:<level>]``, and writes to **stderr**, leaving stdout for the command's
real output:

.. knit-code:: /_code/logging.sh
   :language: bash
   :start-after: # START levels
   :end-before: # END levels

A message prints only when its level is at or above the current threshold. The
levels, from most to least verbose, are ``trace`` < ``debug`` < ``info`` <
``warning`` < ``error`` < ``critical``. The default threshold is ``info``, so
``knit_trace`` and ``knit_debug`` stay silent until you ask for them.

Set the threshold two ways. Before launch, export the ``KNIT_LOG_LEVEL``
environment variable; from inside a script, call ``knit_log_set_level``:

.. knit-code:: /_code/logging.sh
   :language: bash
   :start-after: # START setlevel
   :end-before: # END setlevel

``KNIT_LOG_LEVEL=trace ./exp.sh work`` turns everything on for one run without
touching the script. An invalid level is rejected: ``knit_log_set_level``
returns non-zero and leaves the level unchanged, and an invalid
``KNIT_LOG_LEVEL`` is reset to ``info`` with a warning when knit loads.

``knit_fatal`` is the odd one out: it prints at **any** level and then exits the
process with status 1, so reach for it only when the command cannot continue. If
knit has captured a subprocess's output in its trace file, the fatal message
also points you at that file.
