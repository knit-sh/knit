Part III --- Searching for the best architecture
=================================================

Tired of the ``julia-fractal`` example? Good news, we are going to use a new
one: training a convolutional neural network (CNN) on an image dataset (CIFAR-10).
Such a CNN can be configured with various numbers of layers or kernel sizes, and
can be trained with various hyperparameters. But how do we know which architecture
is the best? This matters: if the goal of an experiment is to compare a new approach
to image classification against a state-of-the-art CNN, we better be sure to configure
the latter as best as we can.

This part of the tutorial will introduce a number of features, including uv-based
setups (as opposed to the previously used spack-based ones), domain descriptions,
parameter sweeps, and parameter-space exploration using Bayesian optimization.

We build ``exp.sh`` up as we go: Steps 1--2 start with a ``train`` job that
searches three parameters, and Step 8 grows it to eight. So the command output
shown along the way reflects the file *at that step*, not the finished script ---
the complete version appears at the end, in `The complete experiment (Part III)`_.

.. note::

   This part runs on a laptop. Unlike Part I it needs no compiler or MPI, but it
   does need the **uv** plugin's prerequisites (a network connection and the
   ability to run `uv <https://docs.astral.sh/uv/>`_, which bootstrap provisions
   for you) and enough time and memory to train a small network on CPU. A GPU is
   not required. As in Part I, every step's code is shown in full and was
   validated end to end during development; the console output is illustrative.

The program
-----------

Like ``julia-fractal``, the trainer lives in its own public repository,
`image-classifier-example
<https://github.com/knit-sh/image-classifier-example>`_ (the ``cifar-cnn``
program). We do not reproduce its source here; we treat it as a black box with a
simple contract. It is a real PyTorch program that:

- reads a CNN architecture from command-line arguments (number of convolution
  blocks, channels per block, kernel size, and --- later --- dropout, activation,
  learning rate, and more);
- trains that architecture on CIFAR-10 for a few epochs;
- prints its final validation accuracy on a stable, machine-readable line,
  ``RESULT val_accuracy=<percent>``, which the job reads back and records.

It is installable as a Python package, so the setup can point **uv** straight at
the repository and get a pinned, reproducible environment *and* the program
itself in one step. That contract --- *these arguments in, an accuracy out* --- is
all we need; the PyTorch internals stay out of view.

.. _tutorial-part3-step1:

Step 1 --- One training run
---------------------------

The first step provisions the environment and runs a single architecture. Three
registrations do it: a **setup** that installs the program, a **resource** that
downloads the dataset, and a **job** that trains one network and records its
accuracy.

Part I provisioned a C++ toolchain with the **Spack** plugin. An ML stack is a
better fit for **uv**, so Part III imports that plugin instead and declares a
uv-backed setup. The setup names one requirement --- the ``cifar-cnn`` package,
installed directly from its Git repository --- and has no body of its own; uv
building and activating the environment is all it does:

.. knit-code:: ../_code/cnn_train.sh
   :language: bash
   :start-after: # START setup
   :end-before: # END setup

Because a uv-backed setup is declared, ``bootstrap`` provisions a knit-private uv
automatically. uv installs the program and pins the exact dependency set
(``pyproject.toml`` / ``uv.lock``) as provenance, so a reproducer gets the same
environment.

The CIFAR-10 dataset is an input, so it is a **resource**. ``@with_url`` makes
``cifar`` a downloadable resource with a default URL; ``knit fetch`` downloads
and (with ``--uncompress``) unpacks it once into ``resources/``, recording the
URL:

.. knit-code:: ../_code/cnn_train.sh
   :language: bash
   :start-after: # START resource
   :end-before: # END resource

.. note::

   Probably due to CIFAR-10's popularity, download is usually slow from its
   source website.

Finally the ``train`` job. It depends on the setup (so ``cifar-cnn`` is on
``PATH``) and the resource (so the dataset is staged), runs ``cifar-cnn train``,
parses the ``RESULT val_accuracy=`` line, and records the number as a declared
**output** --- the column every later step reads as the objective:

.. knit-code:: ../_code/cnn_train.sh
   :language: bash
   :start-after: # START job
   :end-before: # END job

Bootstrap, fetch the data, build the environment, and train one network:

.. code-block:: console

   $ ./exp.sh bootstrap
   $ ./exp.sh fetch --name cifar -- cifar --uncompress
   $ ./exp.sh setup --name cnnenv -- cnnenv
   $ ./exp.sh submit --setup cnnenv --wait -- train --data cifar
   ...
   RESULT val_accuracy=63.7

That run used every parameter's default. The recorded ``val_accuracy`` is the single
number the rest of this tutorial works to maximize.

.. note::

   You may have noticed each parameter already carries a ``--domain``
   annotation. The job runs fine without it --- every parameter has a default ---
   so we glossed over it just now. It is the subject of the next step.

.. _tutorial-part3-step2:

Step 2 --- Declare the search space
-----------------------------------

To *search* for the best architecture we first have to say what "all
architectures" means: the set of values each parameter may take. That is the parameter's
**domain**, which you may already have spotted on the ``train`` job above. It is
declared with ``--domain`` right where the parameter is declared --- a range
``[lo..hi]`` for a count (``num-blocks``), or a set ``{a,b,c}`` for a discrete
choice (``base-channels``, ``kernel-size``). Quote the descriptor so the shell
does not brace-expand ``{...}``. Parameters that are not searched --- ``dataset``
(fixed per run) and ``epochs`` (kept small so a run finishes fast) --- simply
carry no domain. A domain changes nothing about how the job runs on its own; it
is a declaration the search tools read.

Those declarations are the single source of truth for the rest of the part, and
you can read them back at any time with ``./exp.sh describe --space``:

.. code-block:: console

   $ ./exp.sh describe --only 'submit train' --space
   submit train
   ------------
     [job, user]  Train the CNN and record its validation accuracy.

     Options
     -------
       --help                   Print this help message and exit.
       --data <value>           [required, resource: cifar] Name of the fetched CIFAR instance.
       --dataset <value>        [default: 'cifar10'] Dataset loader (not searched).
       --num-blocks <value>     [default: '3', range [1,5]] Convolution blocks.
       --base-channels <value>  [default: '32', values {16,32,64}] Channels in the first block.
       --kernel-size <value>    [default: '3', values {3,5}] Convolution kernel size.
       --epochs <value>         [default: '3'] Training epochs (not searched).

     Outputs
     -------
       val-accuracy  [real, default: '0'] Final-epoch validation accuracy (%).

With the space declared, the obvious next move is to try more than one point in
it.

.. _tutorial-part3-step3:

Step 3 --- A sweep by hand
--------------------------

One training run tells us nothing about which architecture is best; we need to
compare several. The first thing anyone reaches for is a shell loop over the two
discrete parameters:

.. code-block:: console

   $ for nb in 2 3 4; do
       for ks in 3 5; do
         ./exp.sh submit --setup cnnenv --wait -- train --data cifar \
             --num-blocks "$nb" --kernel-size "$ks"
       done
     done

This works --- it trains all six architectures and records six ``val_accuracy``
rows --- but it is unsatisfying in three ways. The grid is hard-coded in shell,
not derived from the domains we just declared, so it can silently drift from
them. The six runs share no common label, so nothing ties them together as one
experiment. And it is **not resumable**: if the machine reboots after the fourth
run, the loop starts over from the first. Each of these is a reason to let Knit
build the grid for us.

.. _tutorial-part3-step4:

Step 4 --- ``knit sweep``
-------------------------

``knit sweep`` replaces the loop. It runs the existing ``train`` job once per
point of a cartesian product, where each swept parameter takes *sweep-syntax* in
place of a value: an explicit set ``'{2,3,4}'``, or ``@domain`` to draw from the
parameter's declared ``--domain``. The ``--group grid`` on the ``submit`` line
tags every job the sweep produces with one campaign label, so you can later
drain, inspect, or remove them as a unit. Here is the six-point grid, run two at
a time:

.. code-block:: console

   $ ./exp.sh sweep --max-inflight 2 -- submit --group grid --setup cnnenv --wait \
         -- train --data cifar --num-blocks '{2,3,4}' --kernel-size '{3,5}'

Quote the sets so the shell does not brace-expand them. Preview the expansion
without running anything by inserting ``--dry-run`` right after ``sweep``; it
prints the reconstructed command lines and exits. Notice that the entire
``submit`` line --- ``--group``, ``--setup``, and all --- is replicated verbatim
for each point, with only the swept parameters changing:

.. code-block:: console

   $ ./exp.sh sweep --dry-run -- submit --group grid --setup cnnenv -- train \
         --data cifar --num-blocks '{2,3,4}' --kernel-size '{3,5}'
   submit --group grid --setup cnnenv -- train --data cifar --num-blocks 2 --kernel-size 3
   submit --group grid --setup cnnenv -- train --data cifar --num-blocks 2 --kernel-size 5
   submit --group grid --setup cnnenv -- train --data cifar --num-blocks 3 --kernel-size 3
   submit --group grid --setup cnnenv -- train --data cifar --num-blocks 3 --kernel-size 5
   submit --group grid --setup cnnenv -- train --data cifar --num-blocks 4 --kernel-size 3
   submit --group grid --setup cnnenv -- train --data cifar --num-blocks 4 --kernel-size 5

This is where the domains of Step 2 pay off. Give a parameter ``@domain`` instead
of an explicit set and the sweep draws its values straight from the declared
domain, so the grid can never drift from it. ``--num-blocks @domain`` expands to
the whole ``[1..5]`` range:

.. code-block:: console

   $ ./exp.sh sweep --dry-run -- submit -- train \
         --data cifar --num-blocks @domain --kernel-size '{3,5}'
   submit -- train --data cifar --num-blocks 1 --kernel-size 3
   submit -- train --data cifar --num-blocks 1 --kernel-size 5
   ... six more ...
   submit -- train --data cifar --num-blocks 5 --kernel-size 3
   submit -- train --data cifar --num-blocks 5 --kernel-size 5

Beyond running the jobs, the sweep records itself: each child job carries a
provenance edge back to the sweep, so the whole grid can be queried as one unit
later (we use that in the inspection step). One command, one label, and the grid
is derived from the declared space --- two of the three complaints from Step 3
are gone. But this ephemeral form still runs the whole sweep inside one
foreground process. Lose that process --- a closed laptop, a dropped connection
--- and the sweep stops where it was. The third complaint, resumability, needs
one more move.

.. _tutorial-part3-step5:

Step 5 --- Durable prepare and drain
------------------------------------

The fix is to separate *planning* the sweep from *running* it. Point the sweep at
``prepare`` instead of ``submit`` and it records one job per grid point in the
``prepared`` state, contacting no scheduler:

.. code-block:: console

   $ ./exp.sh sweep -- prepare --group grid --setup cnnenv -- train \
         --data cifar --num-blocks '{2,3,4}' --kernel-size '{3,5}'

The whole submission spec --- the ``--group`` label, the setup, and on a cluster
the nodes, walltime, and queue --- is frozen at prepare time, which is why those
options go on the ``prepare`` line. The six jobs now sit durably in the database
as a to-do list. Release them with ``submit drain``, which keeps up to
``--max-inflight`` jobs alive at once:

.. code-block:: console

   $ ./exp.sh submit drain --group grid --max-inflight 2

Resumability is now a property of the queue, not of any one process. If a drain
is interrupted, the finished jobs stay recorded and the unreleased ones stay
``prepared``; running ``submit drain --group grid`` again picks up exactly where
it left off. This prepare-then-drain shape is the backbone of the rest of the
part.

.. _tutorial-part3-step6:

Step 6 --- Run the sweep inside a pilot job
-------------------------------------------

Everything so far runs fine on a laptop. On a cluster, though, ``submit drain``
releases each ``train`` job to the *batch scheduler*, so every job waits in the
queue on its own --- six queue waits for a six-point grid, and far more once the
search grows. We would rather wait in the queue **once**, get an allocation, and
run the whole sweep inside it.

That is what a **pilot job** does. A job marked ``@with_pilot`` takes one
allocation and starts the in-allocation ``knit-pilotd`` daemon over its nodes;
from inside its body, every ``knit submit`` --- including the ones ``submit
drain`` issues --- targets that daemon instead of the batch scheduler, so the
drained jobs pack onto the pilot's own nodes with no second queue wait. To fill
those nodes rather than use them one at a time, the drain runs several jobs at
once: the body sizes ``--max-inflight`` to the allocation's node count (one
single-node ``train`` per node), read with ``knit_job_hostnames`` from inside the
pilot:

.. knit-code:: ../_code/cnn_pilot.sh
   :language: bash
   :start-after: # START pilot
   :end-before: # END pilot

The pilot trains nothing itself, so it declares ``@without_setup``; each
``train`` job it drains still carries the ``--setup cnnenv`` frozen into it at
prepare time. Prepare the sweep as in Step 5, then submit the pilot over as many
nodes as you want the jobs to pack onto:

.. code-block:: console

   $ ./exp.sh sweep -- prepare --group grid --setup cnnenv -- train \
         --data cifar --num-blocks '{2,3,4}' --kernel-size '{3,5}'
   $ ./exp.sh submit --nodes 4 --wait -- sweep-pilot --group grid

The ``submit drain`` call is the part that does the draining. The two calls
before it --- ``job reconcile`` and ``job reset`` --- are there for a different
reason: surviving a walltime kill, which is the subject of the next step.

.. note::

   By default the daemon shares the pilot's first node with the jobs it drains onto
   the allocation. The daemon is not compute-intensive, so this is usually fine. But
   if there is any chance it perturbs the sub-jobs in a way that matters --- most
   often when a sub-job's own run time is part of what the experiment measures ---
   it is better to keep that node for the daemon alone: allocate one extra node and
   declare the pilot with ``@with_pilot --exclude-launch-host``, which drops the
   daemon's host from the pool so the sub-jobs run on the other nodes only.

.. _tutorial-part3-step7:

Step 7 --- One pilot, resumed until the sweep is done
-----------------------------------------------------

A pilot runs under a wall-clock limit. A large sweep may not finish inside one
allocation's walltime, and when the limit is reached the scheduler kills the
pilot with ``SIGKILL``. That hard kill gives the compute-side bookkeeping no
chance to run, so the jobs that happened to be mid-flight are left stranded:
their rows stay in ``running`` or ``submitting`` state forever, even though
nothing is running them. The still-``prepared`` remainder of the sweep is
untouched, but those stranded jobs would never run again on their own.

The pilot body handles this in three moves, which is why it is written the way it
is:

#. ``job reconcile`` asks the scheduler the true fate of every ``running`` /
   ``submitting`` job in the group and corrects the stranded rows to ``killed``.
#. ``job reset`` moves those ``killed`` jobs back to ``prepared``, so they are
   eligible to run again.
#. ``submit drain`` drains the whole ``prepared`` set --- the recovered jobs plus
   whatever never got released the first time.

On the pilot's **first** run there is nothing stranded and nothing killed, so the
first two calls are no-ops and the third simply drains the sweep. On a **resume**
they recover the interrupted jobs and the drain carries on. So resuming a sweep
that ran out of walltime is just resubmitting the very same pilot, with more
walltime, or as many times as it takes:

.. code-block:: console

   $ ./exp.sh submit --walltime 06:00:00 --nodes 4 --wait -- sweep-pilot --group grid

The sweep's product is **prepared once** and lives durably in the database; the
pilot is a stateless drainer that re-enters the reconcile → reset → drain cycle
every time it starts. That division --- a durable plan, a disposable runner --- is
the operational payoff of the whole prepare/drain design.

.. note::

   The three calls can be collapsed into one command: ``submit drain`` takes
   ``--reconcile`` (do the reconcile pass first) and ``--retry killed,failed``
   (re-queue those states before draining), so the body could read simply
   ``knit submit drain --group grid --reconcile --retry killed,failed``. The
   three-step form is spelled out here because it shows exactly which state each
   call repairs.

.. _tutorial-part3-step8:

Step 8 --- When the grid explodes: Bayesian optimization
--------------------------------------------------------

The grid in Steps 3--5 swept two parameters. A good architecture depends on more
than two, though. Suppose we also let the search vary the dropout rate, the
activation function, whether the network uses residual connections, the learning
rate, and the batch size --- five more parameters on the ``train`` job:

.. knit-code:: ../_code/cnn_ax.sh
   :language: bash
   :start-after: # START newparams
   :end-before: # END newparams

The search space is now eight-dimensional. Even at a handful of values per
parameter the cartesian product runs to **thousands** of trainings --- days or
weeks of compute to enumerate exhaustively, most of it spent on architectures
that were never going to be good. A grid is the wrong tool at this size.

The right tool is **adaptive** search: instead of enumerating every point, build
a model of how the parameters affect accuracy, and let it propose the next
architecture to try based on everything seen so far. That is Bayesian
optimization, and Knit provides it through the **ax** plugin (``knit_import
ax``). It drives the *same* ``train`` job --- it only changes how the next set of
parameters is chosen.

Like the durable sweep, an ax search is prepared, then run. ``ax prepare``
records a *campaign*: the objective column and its direction (``--objective
val_accuracy --maximize``), the campaign's lifetime trial budget
(``--max-trials``), a quasi-random warm-up (``--sobol-trials``), and an RNG
``--seed`` for reproducibility. The downstream is an ordinary ``submit -- train``
line, with ``@domain`` on each parameter ax should search (drawing from the
``--domain`` declared in Step 2) and a fixed value on the rest:

.. code-block:: console

   $ ./exp.sh ax prepare --campaign tune --objective val_accuracy --maximize \
         --max-trials 40 --sobol-trials 8 --seed 1 \
         -- submit --setup cnnenv -- train --data cifar \
            --num-blocks @domain --base-channels @domain --kernel-size @domain \
            --dropout @domain --activation @domain --residual @domain \
            --lr @domain --batch-size @domain

``ax optimize`` then runs the loop: it asks the model for a set of parameters,
submits a ``train`` job with them, reads back ``val_accuracy``, tells the model
the result, and repeats until the budget is spent --- converging on a strong
architecture in dozens of trainings rather than thousands:

.. code-block:: console

   $ ./exp.sh ax optimize --campaign tune

The optimizer runs in a private uv-backed environment that is built during bootstrap.
It is resumable: interrupt it and run the same command
again to continue from the campaign's persisted state. Two per-call options shape
a run: ``--max-inflight N`` keeps ``N`` trials in flight at once, and ``--trials
K`` stops after ``K`` more trials (handy for advancing a long campaign in bounded
chunks). When a campaign reaches its ``--max-trials`` budget but you want to keep
searching, raise the budget with ``ax extend --campaign tune --max-trials 80``
and run ``ax optimize`` again.

Running it inside a pilot works exactly as in Step 6 --- a pilot will call
``ax optimize`` instead of ``submit drain``, so every trial the loop submits
packs onto the pilot's allocation:

.. knit-code:: ../_code/cnn_ax.sh
   :language: bash
   :start-after: # START pilot
   :end-before: # END pilot

Prepare the campaign, then submit the pilot over enough nodes for the trials to
overlap --- the pilot's ``ax optimize --max-inflight`` (see the job body above)
decides how many run at once. Resuming a campaign the walltime cut short is,
again, just resubmitting the same pilot at the same campaign --- ax keeps the
trials already done and continues the rest:

.. code-block:: console

   $ ./exp.sh ax prepare --campaign tune-p --objective val_accuracy --maximize \
         --max-trials 40 --sobol-trials 8 --seed 1 \
         -- submit --setup cnnenv -- train --data cifar \
            --num-blocks @domain --base-channels @domain --kernel-size @domain \
            --dropout @domain --activation @domain --residual @domain \
            --lr @domain --batch-size @domain
   $ ./exp.sh submit --nodes 4 --wait -- tune-pilot --campaign tune-p --max-inflight 4

.. note::

   Trial run times can spread widely: a small ``--batch-size`` does more steps
   per epoch, and a large ``--base-channels`` or ``--num-blocks`` makes a heavier
   CNN, so one trial can take many times longer than another. Size the
   ``--max-trials`` budget and the walltime for the slow end of the range, not the
   average.

.. _tutorial-part3-step9:

Step 9 --- State the finding
----------------------------

The search is done; now let's read the answer back. ``ax show`` summarizes a campaign
--- its status, how many trials ran, and the best objective value seen:

.. code-block:: console

   $ ./exp.sh ax show --campaign tune
   campaign:   tune
   status:     completed
   objective:  val_accuracy (maximize)
   trials:     40/40
   seed:       1
   best:       78.4
   opt-id:     tune
   command:    submit --setup cnnenv -- train --data cifar --num-blocks @domain ...

That gives the best *score*, but we asked a question about an *architecture*.
Every ``train`` run recorded its parameters and accuracy in the ``train`` table
(as in Part I), so a one-line query returns the winning configuration --- the best
of everything we tried, grid and campaign alike:

.. code-block:: console

   $ ./exp.sh query sql --format column --header --exec "
       SELECT num_blocks, base_channels, kernel_size, activation, residual,
              round(lr, 4) AS lr, batch_size, val_accuracy
       FROM train ORDER BY val_accuracy DESC LIMIT 1"
   num_blocks  base_channels  kernel_size  activation  residual  lr      batch_size  val_accuracy
   ----------  -------------  -----------  ----------  --------  ------  ----------  ------------
   4           64             3            gelu        true      0.0123  128         78.4

We can now answer the question this part opened with, in one plain sentence: *on
CIFAR-10, the best architecture we found is a four-block CNN with 64 base
channels, 3×3 kernels, GELU activations and residual connections, trained at a
learning rate near 0.012 --- it reaches 78.4% validation accuracy.* Record the
finding alongside the runs so it travels with the experiment:

.. code-block:: console

   $ ./exp.sh metadata store --key best-architecture \
         --value "4 blocks, 64 channels, k3, gelu, residual, lr~0.012 -> 78.4% val acc (campaign tune)"

That is where Part III ends: a finding, stated in English and backed by every
recorded run that led to it.

.. note::

   **Beyond finding the best point.** The same campaign machinery can fit a
   *surrogate model* of the objective instead of chasing its optimum. Prepare with
   ``ax prepare --model`` (in place of ``--maximize`` / ``--minimize``) and the
   loop explores where the model is least certain. You then ask the fitted model
   for the objective at any in-space point with ``ax predict`` --- written as the
   prepare command with a concrete value in each varying position --- and check
   the model's fit with ``ax show --diagnostics``. The *Optimize a job with
   Bayesian search* recipe in the Stitch Guide covers it.

The complete experiment (Part III)
----------------------------------

Here is the whole experiment in one file --- the setup, the resource, the
eight-parameter ``train`` job, and the two pilots (``sweep-pilot`` for the grid,
``tune-pilot`` for the campaign). Save it as ``exp.sh`` next to a copy of
``knit.sh``:

.. knit-code:: ../_code/cnn_full.sh
   :language: bash

From a cluster login node, the full arc is: provision, fetch the data, build the
environment, prepare and drain a grid inside a pilot, then prepare and run a
Bayesian campaign inside a pilot, and read the result:

.. code-block:: console

   $ ./exp.sh bootstrap  # on a cluster, add --profile <machine>
   $ ./exp.sh fetch --name cifar -- cifar --uncompress
   $ ./exp.sh setup --name cnnenv -- cnnenv
   $ ./exp.sh sweep -- prepare --group grid --setup cnnenv -- train \
         --data cifar --num-blocks '{2,3,4}' --kernel-size '{3,5}'
   $ ./exp.sh submit --nodes 4 --wait -- sweep-pilot --group grid
   $ ./exp.sh ax prepare --campaign tune --objective val_accuracy --maximize \
         --max-trials 40 --sobol-trials 8 --seed 1 \
         -- submit --setup cnnenv -- train --data cifar \
            --num-blocks @domain --base-channels @domain --kernel-size @domain \
            --dropout @domain --activation @domain --residual @domain \
            --lr @domain --batch-size @domain
   $ ./exp.sh submit --nodes 4 --wait -- tune-pilot --campaign tune --max-inflight 4
   $ ./exp.sh ax show --campaign tune

On a laptop it is the same script with no pilots: drain the grid directly with
``submit drain --group grid`` and run the campaign with ``ax optimize --campaign
tune``. The experiment script never changes.
