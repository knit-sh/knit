..
   title: Register an MPI app
   categories: apps
   order: 10
   description: Declare an app with knit_register_app; its body runs once per MPI rank, and knit records outputs from rank 0 only.
   apis: knit_register_app, knit_output

An **app** is the unit ``knit run`` launches across an MPI world: knit starts one
copy of its body per rank. Register it with ``knit_register_app`` --- it takes
parameters, types, and outputs exactly like a job or a plain command:

.. knit-code:: /_code/julia_app.sh
   :language: bash
   :start-after: # START app
   :end-before: # END app

The body above runs on **every rank**. It calls ``julia-fractal`` as a child
process (not ``exec``), so that child inherits the launcher's MPI environment and
the copies join one ``MPI_COMM_WORLD`` and split the work. A body that needs to
branch on its own rank reads the environment knit normalizes for it --- see
*Read a rank's place in the MPI world*.

Recording is automatic but **rank-0 only**: knit suppresses row and output
recording on every rank but rank 0, so a single ``knit_output`` (see the
``inside`` metric above) writes one row no matter how many ranks ran. You do not
need to guard it with a rank check.

An app is not submitted directly --- a job launches it with ``knit run`` (see
*Launch an app from a job*).
