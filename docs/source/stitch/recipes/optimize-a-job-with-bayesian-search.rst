..
   title: Optimize a job with Bayesian search
   categories: search
   order: 80
   description: Tune a job's recorded output with the knit-ax plugin's Bayesian ask/tell loop over a declared search domain.
   apis: knit_import, knit_with_optional, knit_with_output, knit_with_table, knit_get_parameter, knit_output

The **knit-ax** plugin runs Bayesian optimization over a knit command. Where
``knit sweep`` tries every point in a product, ``ax`` fits a model to the results
so far and asks it where to look next --- the right proposer when each trial is
expensive and the space is large. Import the plugin, then write an ordinary job
whose tunable parameter carries a search ``--domain`` and whose figure of merit is
a declared output:

.. knit-code:: /_code/ax.sh
   :language: bash
   :start-after: # START job
   :end-before: # END job

A run is a **campaign**: a named, resumable record stored on disk under
``campaigns/<name>/`` (a sibling of ``setups/`` and ``jobs/``, so ``knit bundle``
packs it). Two commands drive it, mirroring ``prepare`` then ``submit drain``:
``ax prepare`` validates the request, resolves the objective, builds the search
space, and records the campaign without running a trial; ``ax optimize`` starts
--- or resumes --- the ask/tell loop toward the budget. First run and every resume
are the same call, so a campaign interrupted at walltime continues from its
persisted state:

.. code-block:: console

   # define the campaign (runs nothing); the objective is a declared output,
   # the varying knob is drawn from its domain with @sweep:
   $ ./exp.sh ax prepare --campaign tune --objective score --maximize \
         --trials 20 --parallel 4 --seed 1 -- submit -- quad --x @sweep
   # drive the loop (re-run to resume after an interruption):
   $ ./exp.sh ax optimize --campaign tune
   $ ./exp.sh ax list                  # one line per campaign: status, trials, best
   $ ./exp.sh ax show --campaign tune  # one campaign's detail and current optimum

Each trial is a real ``knit submit`` into the campaign's group, so the trials
are ordinary tracked jobs: ``--parallel`` keeps that many in flight, and every
trial records a ``call`` edge back to the campaign's ``optimizations`` row, so a
query can walk a campaign to its children. ``ax`` reads each trial's objective
from the declared output column, feeds it to the Ax model, and records the best
trial on the campaign row and in ``campaigns/<name>/result.json``. ``--minimize``
(the default) or ``--maximize`` sets the sense; ``--sobol-trials`` sets how many
quasi-random trials explore before the model engages; ``--on-failure penalize``
tells the model a fixed penalty for a failed trial instead of dropping it.

The same campaign optimizes an **app** inside one allocation: swap ``-- submit``
for ``-- run`` and give the launch fields, as in ``-- run --procs 8 -- bench
--msg-size @sweep``. App trials share the allocation, so they run sequentially
(``--parallel`` is job-mode only), and the objective is read from the app's own
table. Declare a parameter's domain with ``--domain`` (see *Declare a parameter's
search domain*); ``ax`` and ``knit sweep`` read the very same domains, so a space
written for one proposer serves the other unchanged.
