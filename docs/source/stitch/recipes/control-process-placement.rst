..
   title: Control process placement
   categories: apps
   order: 30
   description: Shape how knit run places ranks with --procs, --procs-per-node, --hostnames, and per-rank CPU/GPU binding options.
   apis: run

``knit run`` takes a set of placement options, all before the ``--``. Give as few
or as many as you like: knit fills the rest from the job's allocation and the
machine's per-node core count.

.. code-block:: console

   $ knit run --procs 32 --procs-per-node 8 -- render --output "${png}"

**How many ranks and where:**

- ``--procs`` --- total number of ranks. If omitted, knit uses one rank per
  allocated core (per-node core count × nodes), or one rank per node when the
  core count is unknown.
- ``--procs-per-node`` --- ranks per node. If omitted, the launcher's default
  distribution applies; ``--procs`` and ``--procs-per-node`` must be consistent
  with the node count (``--procs`` divisible by ``--procs-per-node``).
- ``--hostnames`` --- a comma-separated subset of the job's allocated hosts to
  place on. Each must be one of the job's hosts (see ``knit_job_hostnames``);
  useful to run on part of a larger allocation.

**Per-rank CPU and GPU binding** (all optional, best-effort --- each is
translated to the chosen launcher's native flag, and a backend with no
equivalent warns and skips rather than failing):

- ``--cpus-per-proc`` --- hardware threads reserved per rank.
- ``--bind`` --- CPU binding policy. Knit normalizes the vocabulary
  ``none | core | socket | numa | thread`` to each launcher's spelling; any other
  value is passed through verbatim.
- ``--gpus-per-proc`` --- GPUs reserved per rank.
- ``--gpu-bind`` --- GPU binding policy, passed through to the launcher.

The resolved placement is recorded with the run, so a run's records show exactly
how its ranks were laid out. For anything a flag doesn't cover, pass launcher
arguments verbatim (see *Pick a launcher backend*).
