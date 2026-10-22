..
   title: Run a parameter sweep
   categories: jobs
   order: 70
   description: Run a command, job, or app once per point in a cartesian product of values with knit sweep.
   apis: sweep, submit:drain, knit_with_optional, knit_parameter_space, knit_command_parameters

``knit sweep`` runs a downstream command **once per point in the cartesian
product** of a set of values per parameter. It is the exhaustive, no-model
proposer: you write the exact invocation you would run once, and mark any value
you want to vary in **sweep-syntax**. The sweep is opaque to the downstream
command --- it scans the tokens after ``--`` for sweep-syntax, treats each as an
axis, passes everything else through verbatim, and re-emits the reconstructed
line once per combination.

A value is a swept axis when it is ``{a,b,c}`` (a list), ``[lo..hi]`` /
``[lo..hi:step]`` (a range), ``@glob:<pattern>`` or ``@file:<path>``; quote the
braces and brackets so the shell does not expand them. Everything else passes
through. The downstream command carries an ordinary job here:

.. knit-code:: /_code/sweep.sh
   :language: bash
   :start-after: # START job
   :end-before: # END job

**Ephemeral: run the product now.** Write the real invocation after ``--`` and
mark the swept values. The dispatcher you use (``submit``, ``run``, or a plain
command) selects what each point does; the sweep launches them in-process,
keeping at most ``--parallel`` in flight (default 1):

.. code-block:: console

   # a job per point (3 submissions), grouped as a campaign:
   $ ./exp.sh sweep --group mc -- submit --nodes {1,2} -- sim --n '{1,2,4}'
   # an app per point, inside one allocation:
   $ ./exp.sh sweep -- run --procs {1,2,4} -- stencil --tile '{64,128}'
   # a plain command per point:
   $ ./exp.sh sweep -- sim --n '{1,2,4}'

``--group`` is spliced into each ``submit`` line, so the campaign's jobs share a
``jobs.group``; every point also records an automatic ``call`` edge back to the
sweep's row, so a query can walk a campaign to its children. ``--on-failure
stop`` aborts on the first failed child (``continue``, the default, runs the
whole product). ``--dry-run`` prints each reconstructed command line and exits
without recording or running --- the quickest way to see exactly what a sweep
would do.

**Vary a declared domain.** When a parameter declares a ``--domain`` (see *Declare
a parameter's search domain*), the sweep can draw its values from the
declaration instead of the command line: ``--param @sweep`` opts one parameter in,
``--fill sweep`` opts in *every* unspecified parameter with an enumerable domain,
and ``--param @default`` opts one back out. A real-interval range is bounds-only
and cannot be enumerated, so sweeping one is a hard error with a fix message.
This is the one point where the sweep introspects the target, through the same
accessors a Bayesian-optimization proposer uses (``knit_parameter_space`` /
``knit_command_parameters``):

.. code-block:: console

   $ ./exp.sh sweep --fill sweep -- submit -- sim          # sim --n over its {1,2,4} domain
   $ ./exp.sh sweep -- submit -- sim --n @sweep             # same, opting --n in explicitly

**Durable: prepare now, drain later (resumable).** Swap ``-- submit`` for
``-- prepare`` and the sweep writes the whole product as a durable to-do list ---
one ``prepared`` job per point, no scheduler contact --- then a separate
``submit drain`` releases them. This is the form to use for a large or long
campaign, or whenever you want to resume after an interruption: a drainer that
dies leaves the un-started points still ``prepared``, so re-running drain resumes
exactly the remainder (see *Drain a prepared batch with submit drain* and *Retry
failed or killed jobs*):

.. code-block:: console

   # 1. prepare the product once (durable, grouped):
   $ ./exp.sh sweep --group mc -- prepare -- sim --n '{1,2,4}'
   # 2. drain it -- from the login node, or inside a pilot job:
   $ ./exp.sh submit drain --group mc --max-inflight 8 --reconcile --retry killed,failed

Resumability is not a sweep feature at all --- it is a property of the
prepare/drain queue the sweep writes into. Draining inside a ``knit_with_pilot``
job packs the swept jobs onto the pilot's nodes with no second queue wait; a
pilot killed at walltime is resumed by re-submitting it, where ``--reconcile``
first corrects the sub-jobs the hard kill stranded at ``running`` and ``--retry``
re-queues them. The sweep's own ``--parallel`` / ``--on-failure`` govern only the
ephemeral forms; durable concurrency, recovery, and failure policy are drain's.
