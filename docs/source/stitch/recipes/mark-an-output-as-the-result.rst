..
   title: Mark an output as the result
   categories: recording, artifacts
   order: 40
   description: Flag the output that is what the experiment was for with --result, so knit describe highlights it.
   apis: knit_with_output, knit_output

A command may record several outputs, but usually one of them is *the* result ---
what the experiment was for. Append ``--result`` to its ``knit_with_output``
declaration to say so:

.. knit-code:: /_code/artifacts.sh
   :language: bash
   :start-after: # START result
   :end-before: # END result

``--result`` is orthogonal to the output's type and to recording: it is valid on
**any** output (a scalar such as ``square`` here, or a ``file`` / ``directory``),
and it changes no value and moves no file. It is a declaration-time marker only,
so ``knit describe`` can surface it: the flagged output carries a ``result`` tag
in the human and Markdown views and a ``"result": true`` field in the JSON and
YAML views (see *Describe the command tree*). An unflagged output such as
``note`` reports ``result`` false.

Set the value from the body with ``knit_output`` exactly as for any output (see
*Emit outputs from a command*); the flag lives on the declaration, not the
emission. For a file or directory you also want packaged for export, declare it
with ``knit_with_artifact ... --result`` instead (see *Declare and bind an
artifact*).
