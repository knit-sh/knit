..
   title: Add a dispatcher command
   categories: commands
   order: 50
   description: Forward the trailing arguments to a target the command resolves itself.
   apis: knit_with_dispatch, knit_extra_index

A *dispatcher* takes a target after ``--`` and forwards the remaining arguments to
it. Knit's own ``setup``, ``submit``, and ``run`` are dispatchers --- each takes a
setup, job, or app name after ``--`` and runs it.

``knit_with_dispatch`` marks the command as a dispatcher (which changes its
``--help`` usage line to ``cmd [OPTIONS] -- <target> [OPTIONS]`` and allows the
trailing arguments), and the body reads them with ``knit_extra_index``:

.. literalinclude:: /_code/commands.sh
   :language: bash
   :start-after: # START dispatch
   :end-before: # END dispatch

``knit_extra_index`` returns the index of the first argument after ``--``, so
``"${args[@]:extra_index}"`` is the forwarded target and its arguments.
