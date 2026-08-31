..
   title: Launch an app from a job
   categories: apps
   order: 20
   description: Call knit run --procs N -- <app> from a job body to launch an app across the job's allocation.
   apis: run, knit_register_app, knit_job_nodecount

Apps are launched from inside a **job** body with ``knit run``. The job holds the
scheduler allocation; ``knit run`` places the app's ranks across it:

.. knit-code:: /_code/julia_app.sh
   :language: bash
   :start-after: # START job
   :end-before: # END job

The launch line is the last statement of the job:

.. code-block:: bash

   knit run --procs "$(knit_job_nodecount)" --procs-per-node 1 -- render \
       --width "${width}" --output "${png}"

Everything before the ``--`` configures the launch (how many ranks, where);
everything after names the app and its own parameters. Deriving ``--procs`` from
``knit_job_nodecount`` makes the same body scale: it is ``1`` on a laptop (one
local rank, no MPI needed) and grows to the node count on a cluster, set by
``submit --nodes N``.

``knit run`` records the launch as a row in the ``runs`` table --- the resolved
placement and the app name travel with it --- and it must run **inside a job**
(it reads the surrounding job's allocation). See *Control process placement* to
pin ranks precisely and *Pick a launcher backend* to choose the launcher.
