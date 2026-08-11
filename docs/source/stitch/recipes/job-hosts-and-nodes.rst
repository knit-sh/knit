..
   title: Find the job's hosts and node count
   categories: jobs
   order: 20
   description: Read a running job's allocated hosts and node count from its body.
   apis: knit_job_hostnames, knit_job_nodecount

Inside a job body, ``knit_job_hostnames`` and ``knit_job_nodecount`` report the
placement the scheduler gave the job --- which nodes it got and how many:

.. literalinclude:: /_code/julia_app.sh
   :language: bash
   :start-after: # START job
   :end-before: # END job

``knit_job_hostnames`` prints the allocated hosts, one per line by default. Shape
the output with:

- ``--separator ', '`` --- join the hosts with a custom separator instead of
  newlines.
- ``--json`` --- emit a JSON array (handy for passing hosts to another tool).
- ``--raw`` --- keep the scheduler's verbatim host list, including any repeats
  (e.g. one line per slot); the default deduplicates and keeps first-seen order.
- ``--select <start>:<length>`` --- take a slice of the (0-based) host list, e.g.
  ``--select 0:1`` for just the first host.

``knit_job_nodecount`` prints the number of *distinct* nodes (the deduplicated
host count) --- so a host offering several slots counts once. It pairs naturally
with ``knit run --procs-per-node 1`` to place exactly one rank per node.

Both work off a scheduler too: on a laptop ``knit_job_hostnames`` reports the
local host and ``knit_job_nodecount`` is ``1``, so the same body runs anywhere.
(The ``knit run`` line above launches an MPI app across the allocation; that is
covered in the Apps category.)
