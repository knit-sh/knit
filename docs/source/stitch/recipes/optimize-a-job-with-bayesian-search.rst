..
   title: Optimize a job with Bayesian search
   categories: search
   order: 80
   description: Tune a job's recorded output with the knit-ax plugin's Bayesian ask/tell loop over a declared search domain, or fit a surrogate model and query it with ax predict.
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
   # the varying parameter is drawn from its domain with @domain. --max-trials
   # is the campaign's lifetime budget:
   $ ./exp.sh ax prepare --campaign tune --objective score --maximize \
         --max-trials 20 --seed 1 -- submit -- quad --x @domain
   # drive the loop (re-run to resume); --max-inflight sets this call's concurrency:
   $ ./exp.sh ax optimize --campaign tune --max-inflight 4
   $ ./exp.sh ax list                  # one line per campaign: status, trials, best
   $ ./exp.sh ax show --campaign tune  # one campaign's detail and current optimum
   # reached the budget but want to keep searching? raise it, then optimize again:
   $ ./exp.sh ax extend --campaign tune --max-trials 40
   $ ./exp.sh ax optimize --campaign tune

Each trial is a real ``knit submit`` into the campaign's group, so the trials
are ordinary tracked jobs: on ``ax optimize``, ``--max-inflight`` keeps that many
in flight (per call, default 1) and ``--trials K`` runs at most K more this call
(default: run to the campaign's ``--max-trials``); every trial records a ``call``
edge back to the campaign's ``optimizations`` row, so a query can walk a campaign
to its children. ``ax`` reads each trial's objective from the declared output
column, feeds it to the Ax model, and records the best trial on the campaign row
and in ``campaigns/<name>/result.json``. ``--minimize`` (the default) or
``--maximize`` sets the sense; ``--sobol-trials`` sets how many quasi-random
trials explore before the model engages; ``--on-failure penalize`` tells the
model a fixed penalty for a failed trial instead of dropping it.

The same campaign optimizes an **app** inside one allocation: swap ``-- submit``
for ``-- run`` and give the launch fields, as in ``-- run --procs 8 -- bench
--msg-size @domain``. App trials share the allocation, so they run sequentially
(``--max-inflight`` is job-mode only), and the objective is read from the app's own
table. Declare a parameter's domain with ``--domain`` (see *Declare a parameter's
search domain*); ``ax`` and ``knit sweep`` read the very same domains, so a space
written for one proposer serves the other unchanged.

Model the objective instead of optimizing it
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Sometimes the goal is not the best point but a *model* of how the objective
behaves across the whole space. Prepare with ``--model`` in place of
``--minimize`` / ``--maximize``: the campaign then fits a surrogate by **active
learning**, sending each trial where the model is least certain rather than toward
an optimum. A model campaign records no best, so ``ax show`` lists its varying axes
instead:

.. code-block:: console

   $ ./exp.sh ax prepare --campaign surf --objective score --model \
         --max-trials 20 -- submit -- quad --x @domain
   $ ./exp.sh ax optimize --campaign surf   # spends the budget on active learning
   $ ./exp.sh ax show --campaign surf
   ...
   axes:       quad.x

Ask the fitted model for the objective at a point with ``ax predict``. Write the
point as the prepare command with a concrete value in each varying position; the
value must be in its domain (a member of a ``{...}`` set, or inside a ``[lo..hi]``
range). It prints the predicted value by default; ``--variance``, ``--std``,
``--interval`` (the 95% confidence interval), and ``--json`` add detail:

.. code-block:: console

   $ ./exp.sh ax predict --campaign surf -- submit -- quad --x 6
   93.8
   $ ./exp.sh ax predict --campaign surf --std --interval -- submit -- quad --x 6
   93.8  (±6.7, 95% CI 80.7–106.9)

``ax predict`` works on any campaign that has run trials --- a ``--model`` campaign
or a ``--minimize`` / ``--maximize`` one --- and reads the model only, recording
nothing. ``ax show --diagnostics`` cross-validates the fitted surrogate and reports
its fit quality (R² / RMSE); it refits the model, so it is opt-in.
