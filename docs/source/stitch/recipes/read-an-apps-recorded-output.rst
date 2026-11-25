..
   title: Read an app's recorded output
   categories: apps
   order: 25
   description: After knit run, read the app's recorded row directly through KNIT_LAST_RUN_UUID / KNIT_LAST_RUN_TABLE.
   apis: run, KNIT_LAST_RUN_UUID, KNIT_LAST_RUN_TABLE, KNIT_LAST_COMMAND_UUID, KNIT_LAST_COMMAND_TABLE, knit_output

An app records its outputs on its own row, in the app's own table. A job body that
launched the app with ``knit run`` often needs one of those values back --- a
metric to branch on, a path to pass along. ``knit run`` leaves two handles in the
job body's shell for exactly this:

.. knit-code:: /_code/read_run_output.sh
   :language: bash
   :start-after: # START job
   :end-before: # END job

``KNIT_LAST_RUN_UUID`` is the id of the row the app recorded and
``KNIT_LAST_RUN_TABLE`` is the app's table, so one query reads the metric back ---
no stdout parsing, no provenance walk:

.. code-block:: bash

   accuracy=$(knit query sql --exec \
       "SELECT accuracy FROM ${KNIT_LAST_RUN_TABLE} WHERE id='${KNIT_LAST_RUN_UUID}'")

These handles name the **app** row, one ``run -> run:<app>`` call edge away from
the launch, not the ``runs`` row. For the dispatcher's own row instead, the generic
``KNIT_LAST_COMMAND_UUID`` / ``KNIT_LAST_COMMAND_TABLE`` name the last row *any*
command recorded in this process --- after ``knit run`` that is the ``runs`` row,
and after a ``metadata store`` the ``metadata`` row, and so on.

Both run handles are left empty when a run records no app row (an app that opted
out of recording a failed invocation), so a job body never reads a stale handle
from an earlier run.
