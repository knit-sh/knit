..
   title: Emit outputs from a command
   categories: recording
   order: 20
   description: Declare a result column with knit_with_output and set it from the body with knit_output.
   apis: knit_with_output, knit_output

A command's parameters are its inputs; its **outputs** are the results you want
recorded alongside them. Declare an output at registration with
``knit_with_output name:type description``, then set its value from the body with
``knit_output name value``:

.. knit-code:: /_code/quickstart.sh
   :language: bash
   :start-after: # START scale
   :end-before: # END scale

Outputs are typed exactly like parameters (see *Type-annotate a parameter*): a
value that does not match its declared type is a fatal error. ``knit_output``
may only set an output the command declared, and only from within the command's
own function.

**Unset outputs record NULL.** An output the body never emits with
``knit_output`` is recorded as SQL ``NULL`` --- the honest "not produced" ---
rather than a fabricated value, so a run that crashes or returns early before
computing ``result`` never leaves a misleading number behind. Prefer that for a
measured quantity. When a fixed fallback is genuinely meaningful, declare it with
``--unset``::

   knit_with_output "retries:integer" "Times this job was re-queued." --unset 0

The ``--unset`` value is type-checked against the output's type, so
``--unset foo`` on an ``:integer`` output is a fatal error. Reading NULL back with
``knit query`` renders per output mode (empty in ``csv``, the literal ``NULL`` in
a display mode); ``--nullvalue <text>`` overrides it.

On its own, ``scale`` just computes ``result`` and prints it --- an emitted
output is not persisted until the command has somewhere to record it. Give the
command a table and each declared output becomes one of its columns, filled from
the last ``knit_output`` value (see *Record invocations in a table*; the ``add``
command there records its ``total`` output this way).

Under ``knit run``, only rank 0 records, so a single ``knit_output`` writes one
value no matter how many ranks executed the body --- you do not need to guard it
with a rank check (see *Register an MPI app*).
