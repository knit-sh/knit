Tutorial
========

The :doc:`../quickstart` showed the mechanics of a single recorded command.
This tutorial will walk you towards a real experiment, built from beginning to
end, where each step introduces exactly one new concept.

We build around a real program, `julia-fractal
<https://github.com/knit-sh/julia-fractal-example>`_, a small C++ renderer for
`Julia-set <https://en.wikipedia.org/wiki/Julia_set>`_ fractals. We start with a
plain command that tries to run it and, step by step, turn it into a
Spack-backed, MPI-parallel, fully recorded experiment. By the end you will have
used setups, jobs, apps, and the query and provenance surfaces together on a
single realistic workload.

.. note::

   This tutorial is meant to run on a laptop, with Step 9 moving it to an
   actual supercomputer. Your laptop does not need MPI. However it needs to
   be able to run `Spack <https://spack.io/>`_ (i.e. have python), compile C programs
   (i.e., gcc, make), untar archives (tar) and download from the internet (curl).
   must be available. The code for each step of this tutorial is shown in full and was
   validated end to end during development; the console output is illustrative.

The program
-----------

``julia-fractal`` renders a Julia-set fractal to a PNG image. Its arguments are
positional --- ``width height c_re c_im max_iter`` are required, the rest have
defaults::

   julia-fractal <width> <height> <c_re> <c_im> <max_iter> \
                 [output.png] [colormap] [center_x] [center_y] [zoom]

On completion it prints, on standard output, the number of grid points found to
be inside the set, including a stable machine-readable line ``inside=<count>``
that we will record and aggregate later. The program builds either as a plain
serial binary or, when MPI is available, as a parallel one --- a property the
tutorial relies on when it introduces MPI. This program is representative of
your typical HPC simulation: a bulk-synchronous program that outputs files
and prints some results.

.. _tutorial-step1:

Step 1 --- a command that calls the program
-------------------------------------------

The simplest thing we can do is wrap the program in a Knit command. As in the
Quickstart, the experiment (call it ``exp.sh``) sources ``knit.sh``, registers a
command, and ends with ``knit "$@"``. Here is the command --- every argument is
optional with a sensible default, so it can be run bare:

.. literalinclude:: ../_code/julia_command.sh
   :language: bash
   :start-after: # START julia
   :end-before: # END julia

The body reads each parameter with ``knit_get_parameter`` and calls
``julia-fractal`` with the arguments in the order the program expects.

Bootstrap the experiment once, then run the command:

.. code-block:: console

   $ ./exp.sh bootstrap
   $ ./exp.sh julia
   ./exp.sh: line 39: julia-fractal: command not found

This failure is normal at this stage. Knit found our command and ran it, but
the command itself failed, because nothing has built or installed
``julia-fractal`` yet. It is not on the ``PATH``, so the shell cannot find it.

.. note::

   You may wonder why we wrap julia-fractal in a command like we did. After all,
   it looks more complicated than just calling it as-is. By wrapping it like we
   did, we (1) told Knit about it, in particular what its inputs and outputs are
   so they can be recorded, (2) made it available as a command so Knit has built
   a nice CLI for us to invoke it, and (3) forced all parameters to be explicit
   instead of positional, which prevents mistakes (e.g. swapping ``c-re`` and
   ``c-im``).

.. note::

   You will find the ``./exp.sh bootstrap`` has created multiple folders in the
   current directory: **.knit** contains Knit-maintained databases and toolsl;
   **setups** contains environment instances (it should currently only contain
   a **default** subfolder), and **jobs** will eventually contain a subfolder
   for each job we will submit.

.. _tutorial-step2:

Step 2 --- a setup that builds the program
------------------------------------------

We could build ``julia-fractal`` by hand, but then the experiment would only
run where we happened to build it. A **setup** is Knit's answer: a recorded,
reproducible step that builds an environment once, to be reused by later
commands. Ours builds ``julia-fractal`` from source and installs it.

A setup is registered with ``knit_register_setup``. This one declares the
software it needs with ``knit_with_spack_specs`` --- ``cmake`` and ``libpng``
(no MPI yet; that comes later) --- and its body clones the source, builds it, and

installs it. This setup must come before our earlier definition of the ``julia``
command:

.. literalinclude:: ../_code/julia_setup.sh
   :language: bash
   :start-after: # START setup
   :end-before: # END setup

Two things make this reproducible. ``knit_with_spack_specs`` declares a
`Spack <https://spack.io/>`_ environment: Knit will use Spack to build
``cmake`` and ``libpng`` and activates them *before* the body runs, so
the body finds them regardless of what the host has installed.
And ``KNIT_SETUP_PREFIX`` is a private directory
Knit creates for a setup instance; everything the body installs there is
captured, and exporting ``PATH`` makes the installed binary visible to commands
that depend on the setup.

.. note::

   Because a Spack-backed setup is now declared, the next time
   ``exp.sh`` is executed, Knit will download Spack.

We can now instanciate our setup:

.. code-block:: console

   $ ./exp.sh setup --name myenv -- juliaenv

``setup`` is a *dispatcher*: the options before ``--`` configure the setup
instance (``--name myenv`` names this build), and the arguments after ``--``
select the setup type (``juliaenv``) and pass its own parameters. To build a
different revision, append ``--ref``: ``setup --name myenv -- juliaenv --ref
main``.

Once built, you should see a new folder named **myenv** in the **Setups** directory. This is where the environment was installed.

Now tell the ``julia`` command to depend on the setup. One line, between its
``knit_register`` and ``knit_done``, does it:

.. literalinclude:: ../_code/julia_setup.sh
   :language: bash
   :start-after: # START depends
   :end-before: # END depends

``knit_with_setup "juliaenv"`` adds a ``--setup`` option to the command and,
before the body runs, activates the named setup's environment --- putting the
installed ``julia-fractal`` on ``PATH``. Run it, pointing at the setup we built:

.. code-block:: console

   $ ./exp.sh julia --setup myenv
   Number of grid points within the set: 181
   inside=181

The command now finds the binary and runs it. Notice the ``inside=181`` line:
that is the metric we will record and aggregate later. So far we have run
``julia`` directly, in the foreground. Real HPC work is *submitted* to run in the
background (and, on a cluster, on other nodes) --- which is what the next step
turns ``julia`` into.

As a side note, you now should have a PNG file in your current working directory with a pretty picture of a Julia set.

.. _tutorial-step3:

Step 3 --- submit it as a job
-----------------------------

A **job** is a command you submit rather than run yourself: Knit hands it to the
machine's batch scheduler (Slurm, PBS, ...), which runs it in the background ---
on a laptop, as a local background process; on a cluster, on compute nodes
allocated for it. The experiment does not change shape; the ``julia`` command
simply becomes a job.

The change is one word: register with ``knit_register_job`` instead of
``knit_register``. That makes ``julia`` a subcommand of the builtin ``submit``
command rather than a top-level command. The body is almost the same as before,
with one addition --- it writes its image under ``KNIT_JOB_PREFIX`` (we also
remove the ``output`` parameter of the command, alway outputing *fractal.png*):

.. literalinclude:: ../_code/julia_job.sh
   :language: bash
   :emphasize-lines: 1,23,25
   :start-after: # START job
   :end-before: # END job

Two things are worth calling out. ``KNIT_JOB_PREFIX`` is a private working
directory Knit creates for *each* submission, so every run keeps its own output
alongside the standard output and error Knit captures for the job. Knit runs the
job body with its current directory *already* set to that job directory, so a
bare relative ``fractal.png`` would land in the same place --- we could have
written just that. We still build an absolute path from ``KNIT_JOB_PREFIX`` on
purpose: it says explicitly where the output belongs, and it keeps working even
if the body (or a program it launches) changes directory first. That habit pays
off in a later step, where the body launches its work as separate processes
through ``knit run`` --- an explicit, absolute path stays unambiguous across that
boundary.

The ``knit_with_setup "juliaenv"`` line we added in Step 2 still applies, but for
a job it behaves differently: instead of adding a ``--setup`` option to
``julia``, it makes ``--setup`` a *required* option of ``submit`` (a job always
runs against a setup), and the setup's environment is re-activated on the machine
where the job actually runs.

Submitting uses the ``submit`` dispatcher. Its grammar mirrors ``setup``: the
options *before* ``--`` configure the submission (which setup, how many nodes,
whether to wait, ...), and the arguments *after* ``--`` select the job and pass
its own parameters:

.. code-block:: console

   $ ./exp.sh submit --setup myenv --wait -- julia
   018f2a1b-9c3d-7e4f-8a1b-2c3d4e5f6a7b

``submit`` prints the job's UUID --- its stable, scheduler-independent
identifier. ``--wait`` blocks until the job finishes (without it, ``submit``
returns immediately and the job runs in the background). ``--setup myenv`` points
at the setup instance we built in Step 2.

Because the job ran elsewhere, its output was captured rather than printed to our
terminal. Retrieve it with ``job show stdout``, passing the UUID:

.. code-block:: console

   $ ./exp.sh job show stdout --id 018f2a1b-9c3d-7e4f-8a1b-2c3d4e5f6a7b
   Number of grid points within the set: 181
   inside=181

Knit also tracks each job's lifecycle. ``job list`` shows every submission and
its state (``submitted`` --- ``running`` --- ``completed``), and ``job status
--id <uuid>`` reports one job's current state:

.. code-block:: console

   $ ./exp.sh job list
   018f2a1b-9c3d-7e4f-8a1b-2c3d4e5f6a7b  julia  completed

The same ``submit`` command works unchanged on a laptop and on a supercomputer
--- only the machine (and its scheduler) differ. That portability is the subject
of the final step. For now the job still runs the binary exactly as Step 2 did:
a single, serial process. The next step brings MPI into the picture, starting
with the setup.

.. _tutorial-step4:

Step 4 --- MPI in the setup
---------------------------

``julia-fractal`` can be built as an MPI program: its CMake calls
``find_package(MPI)`` and, when an MPI is present, compiles the parallel binary;
when none is present (Steps 2 and 3) it compiles the serial one. The source is
identical either way --- whether we get a parallel build is decided entirely by
what is in the *environment*. So making the experiment MPI-capable is a change to
the **setup**, not to the experiment code. Two lines change:

.. literalinclude:: ../_code/julia_mpi.sh
   :language: bash
   :start-after: # START setup
   :end-before: # END setup
   :emphasize-lines: 2,3

The two highlighted lines are the whole change. The first adds ``mpi`` to the
Spack specs. ``mpi`` is a Spack *virtual*:
it stands for "some MPI implementation" and Spack picks a concrete provider
(OpenMPI, MPICH, ...) --- either building one or reusing one the site already
exposes to Spack. With an MPI in the environment, CMake now finds it and builds
the parallel binary, and the compiler wrappers (``mpicc`` / ``mpicxx``) and the
launcher (``mpirun`` / ``mpiexec``) are on ``PATH`` while the body runs.

The second change is ``knit_provides_launcher``. Launching an MPI program takes
two things: the program, and a *launcher* to start its ranks and place them on
nodes. On a real cluster the launcher is the site's own (``srun``, the batch
``mpiexec``), and Knit uses it. But a plain laptop has no integrated launcher ---
and here the setup just built an MPI that ships one. ``knit_provides_launcher``
declares exactly that: *"this setup supplies a launcher where the machine has
none."* When the setup builds, Knit detects the MPI it put on ``PATH``, freezes
that choice into the setup's environment, and records it. Later, when a job runs
an MPI application (Step 5), Knit uses the site launcher if there is one and
otherwise falls back to the launcher this setup provided --- so the *same*
experiment launches ranks on a cluster and on a laptop.

.. note::

   ``knit_provides_launcher`` is a fallback, not an override: a launcher the
   machine already integrates always wins, because a site's launcher cooperates
   with its scheduler as intended. The setup's launcher is used only where the
   machine offers none.

The setup now builds the MPI binary. We instantiate it under a *new* name,
``mympienv``, rather than reusing ``myenv`` from Step 2:

.. code-block:: console

   $ ./exp.sh setup --name mympienv -- juliaenv

.. note::

   Setup instance names are unique, and Knit has no command yet to rebuild or
   delete one --- ``setup --name myenv -- juliaenv`` a second time would be
   refused because ``myenv`` already exists. Deleting a setup is not as simple as
   removing its folder: jobs and commands are recorded as having *used* it, and
   that provenance would be left dangling. Until Knit can clean up safely, treat
   setups as append-only and give each build a fresh name (here, ``mympienv``).

Nothing else changes yet. The ``julia`` job is exactly the one from Step 3, and
submitting it against the new setup still runs a single process --- the parallel
binary launched as one rank:

.. code-block:: console

   $ ./exp.sh submit --setup mympienv --wait -- julia
   018f2a1b-9c3d-7e4f-8a1b-2c3d4e5f6a7b

We have built the parallel program and arranged for a launcher, but we are not
launching it in parallel yet: the job body still calls the binary directly. The
next step wraps the binary as an **app** and has the job launch it across ranks
with ``knit run``.

.. _tutorial-step5:

Step 5 --- launch it in parallel with ``knit run``
--------------------------------------------------

Until now the job body ran ``julia-fractal`` itself, as a single process. To run
it across MPI ranks, the job stops calling the binary directly and instead asks
Knit to launch it, with ``knit run``. Its parameters are unchanged from Step 4;
only the body changes:

.. literalinclude:: ../_code/julia_app.sh
   :language: bash
   :start-after: # START job
   :end-before: # END job
   :emphasize-lines: 21-22,29-32

Two Knit calls are new, both usable from any job body. ``knit_job_hostnames``
prints the hosts the scheduler allocated to this job (here joined with commas), so
the job can log or reason about where it landed. ``knit_job_nodecount`` returns
how many distinct nodes that is. The job uses it to launch **one rank per node**
--- ``knit run --procs "$(knit_job_nodecount)" --procs-per-node 1 -- render …`` ---
which is one rank on a laptop and scales with the allocation on a cluster, with no
change to the script. Everything else (the parameters, reading them, the absolute
``KNIT_JOB_PREFIX`` output path) is exactly as in Step 4; where the body used to
call ``julia-fractal`` directly, it now calls ``knit run … -- render``, forwarding
the same values as named parameters.

``knit run``'s grammar mirrors ``submit`` and ``setup``: options *before* ``--``
configure the launch (``--procs`` total ranks, ``--procs-per-node`` how many land
on each node), and the arguments *after* ``--`` select what to launch (``render``)
and pass its parameters.

But ``knit run`` launches something new: an **app**. An app is the unit of
parallel work --- ``knit run`` starts one copy of it per rank. Our job launches an
app called ``render`` that wraps the actual ``julia-fractal`` call. So we register
it, with ``knit_register_app``:

.. literalinclude:: ../_code/julia_app.sh
   :language: bash
   :start-after: # START app
   :end-before: # END app

The app's body is the ``julia-fractal`` call that used to live in the job, plus
one addition. Three things are worth calling out.

First, the body runs on **every rank**: ``knit run`` started one copy per rank,
and because the app *calls* ``julia-fractal`` as a child (rather than ``exec``-ing
it) each copy's binary inherits the launcher's MPI environment and joins one
size-N MPI world. That is what makes ``julia-fractal``'s own work-splitting real
--- rank 0 gathers the image and writes the PNG, the other ranks compute their
slice. Knit also exports ``KNIT_MPI_RANK``, ``KNIT_MPI_SIZE``, and
``KNIT_MPI_LOCAL_RANK`` for an app that needs to branch on its own rank; this one
lets the binary handle that.

Second, the app **records the metric**. ``knit_with_output "inside:integer"``
declares an output column, and ``knit_output "inside" …`` fills it from the
binary's ``inside=`` line. Every rank runs that line, but Knit records outputs
**only from rank 0** (it suppresses recording on the others), so one clean row is
written no matter how many ranks ran. That recorded ``inside`` is what Step 6
queries and aggregates.

Third, the app has **no setup of its own**. ``knit_with_setup`` is a job concept;
an app inherits the environment of the job that launched it, so ``julia-fractal``
is already on ``PATH`` from the job's ``juliaenv`` setup. The job also hands the
app the output path it built from ``KNIT_JOB_PREFIX``. Knit runs each rank in the
directory where ``knit run`` was called --- the job's own directory --- so a bare
relative name would land there too; passing the absolute path is the same good
practice as in Step 3: it is explicit, and it does not depend on the job body's
current directory or on the process boundary the launcher crosses to start each
rank.

.. note::

   The job and the app declare many of the same parameters (``width``,
   ``height``, ``c-re``, …), because the job forwards them to the app. Rather than
   repeat the declarations, you can define them once as a **parameter set** and
   import it into both commands with ``knit_with_parameter_set``. Parameter sets
   are covered in :doc:`Basic Usage <../basic/index>`.

Submitting is **exactly as before** --- ``julia`` is still the job, so the
``submit`` grammar is unchanged. On a laptop the job runs on one node, so
``knit_job_nodecount`` is 1 and a single rank is launched:

.. code-block:: console

   $ ./exp.sh submit --setup mympienv --wait -- julia
   018f2a1b-9c3d-7e4f-8a1b-2c3d4e5f6a7b
   $ ./exp.sh job show stdout --id 018f2a1b-9c3d-7e4f-8a1b-2c3d4e5f6a7b
   The job is running on hosts: my-laptop
   Number of grid points within the set: 181
   inside=181

The payoff is portability: the *same* ``julia`` job scales out just by asking for
more nodes. Submit across an allocation and ``knit_job_nodecount`` reports 2, so
the job launches two ranks, one per node --- the launcher places them for you:

.. code-block:: console

   $ ./exp.sh submit --setup mympienv --nodes 2 --wait -- julia
   018f3b2c-0d4e-7f5a-9b2c-3d4e5f6a7b8c
   $ ./exp.sh job show stdout --id 018f3b2c-0d4e-7f5a-9b2c-3d4e5f6a7b8c
   The job is running on hosts: node07, node08
   Number of grid points within the set: 181
   inside=181

Nothing in the experiment script changes between the two; only the node count (and
the machine) differs. The next step turns to the records these runs left behind
--- querying and aggregating the ``inside`` metric across many renders.

Step 6 --- query and aggregate the results
------------------------------------------

Every ``render`` recorded one row, from rank 0, in a table named after the app.
Those rows accumulate: submit ``julia`` a few times --- here with different Julia
constants, so each produces a different image --- and the database holds one
``render`` row per run:

.. code-block:: console

   $ ./exp.sh submit --setup mympienv --wait -- julia --c-re -0.123 --c-im 0.745   # Douady rabbit
   $ ./exp.sh submit --setup mympienv --wait -- julia --c-re -1.0   --c-im 0.0     # Basilica
   $ ./exp.sh submit --setup mympienv --wait -- julia --c-re -0.391 --c-im -0.587  # Siegel disk
   $ ./exp.sh submit --setup mympienv --wait -- julia --c-re 0.285  --c-im 0.535   # period-3 lobe
   $ ./exp.sh submit --setup mympienv --wait -- julia --c-re -0.7   --c-im 0.0     # San Marco dragon
   $ ./exp.sh submit --setup mympienv --wait -- julia --c-re -1.25  --c-im 0.0     # period-4 bulb
   $ ./exp.sh submit --setup mympienv --wait -- julia --c-re -0.1   --c-im 0.651   # near-dendrite (tiny interior)

Each constant sits inside a hyperbolic component of the Mandelbrot set, so its
Julia set has a genuine black interior for ``inside`` to count --- unlike a
*dendrite* constant (e.g. ``-0.4 0.6``), whose picture is intricate but has zero
interior area, so it would record ``inside=0``.

Knit gives you three ways to read those records back.

**The schema, with** ``query catalog``. It lists every table Knit is recording
into and the columns of each. Our app's outputs show up under the ``render``
table --- notice the ``inside`` column we declared, alongside the parameters:

.. code-block:: console

   $ ./exp.sh query catalog --ref render
   table render
     column id (TEXT)
     column width (INTEGER)
     column height (INTEGER)
     column c_re (REAL)
     column c_im (REAL)
     column max_iter (INTEGER)
     column colormap (TEXT)
     column output (TEXT)
     column inside (INTEGER)

(Declared parameter names with hyphens become columns with underscores, so
``c-re`` is stored as ``c_re``.)

**The raw rows, with** ``query sql``. It runs a read-only SQL statement against
that database (any statement that would write is refused), so you can look at
exactly what was recorded:

.. code-block:: console

   $ ./exp.sh query sql --format column --header \
       --exec "SELECT c_re, c_im, inside FROM render ORDER BY inside"
   c_re    c_im    inside
   ------  ------  ------
   -0.1    0.651   890
   -1.25   0.0     34164
   0.285   0.535   67424
   -0.123  0.745   69456
   -1.0    0.0     74800
   -0.391  -0.587  78043
   -0.7    0.0     119960

**A packaged fan-in, with your own command.** Reading the same table from a
command turns an ad-hoc query into a reusable part of the experiment. This
``aggregate`` command totals ``inside`` across *every* render, no matter which
job produced it --- a *fan-in*, the counterpart to the fan-out of submitting many
jobs:

.. literalinclude:: ../_code/julia_aggregate.sh
   :language: bash
   :start-after: # START aggregate
   :end-before: # END aggregate

It calls ``knit query sql`` from inside the body, exactly as you would from the
shell. ``knit_without_provenance`` marks the command as read-only bookkeeping: it
reads results but is not itself part of the experiment's provenance, so running it
records no row and leaves no ``call`` edge in the graph. Running it collapses the
three renders into one number:

.. code-block:: console

   $ ./exp.sh aggregate
   Summed inside=444737 over 7 render(s).

**The provenance graph, with** ``query graph``. ``query sql`` reads columns from
one table; ``query graph`` follows the *relationships* Knit records between rows
--- which submission called which job, which job launched which run, which run
produced which render. It runs `Cypher <https://opencypher.org/>`_, matching a
path through the graph. Each node's label is a table name, and ``-[:call]->`` is
the "called" edge Knit draws from a command to what it invoked. So to walk from
each ``julia`` job down to the ``render`` it produced --- two tables that no single
SQL query would join without knowing the provenance --- and read the metric back:

.. code-block:: console

   $ ./exp.sh query graph --format column --header \
       --exec "MATCH (job:julia)-[:call]->(:run)-[:call]->(img:render)
               RETURN job.id, img.c_re, img.inside"
   job.id                                img.c_re  img.inside
   ------------------------------------  --------  ----------
   018f2a1b-9c3d-7e4f-8a1b-2c3d4e5f6a7b  -0.123    69456
   018f3b2c-0d4e-7f5a-9b2c-3d4e5f6a7b8c  -1.0      74800
   018f4c3d-1e5f-7a6b-0c3d-4e5f6a7b8c9d  -0.391    78043
   018f5d4e-2f6a-7b7c-1d4e-5f6a7b8c9dae  0.285     67424
   018f6e5f-3a7b-7c8d-2e5f-6a7b8c9daebf  -0.7      119960
   018f7f6a-4b8c-7d9e-3f6a-7b8c9daebfc0  -1.25     34164
   018f8a7b-5c9d-7eaf-4a7b-8c9daebfc0d1  -0.1      890

The path mirrors how the run actually happened: ``submit`` called the ``julia``
job, the job's body called ``knit run``, and the run launched the ``render`` app.
Because that history is recorded as a graph, you can ask questions that span the
whole chain --- for example, following the ``used_by`` edge back to the setup a
render's job consumed --- rather than only what lives in a single table.

The provenance model, ``knit query`` in full, and analysis commands are covered
in :doc:`Basic Usage <../basic/index>`. Knit's experimental model fans out from
a single bootstrap to multiple setups, each used by multiple jobs, each potentially
running one or more apps, before a fan-in command aggregates the result to, for
instance, produce figures. That entire lineage is a single path in Cypher:
starting from a setup, follow its ``used_by`` edge to every job that consumed it,
then the ``call`` edges down to each job's run --- one row per run:

.. code-block:: console

   $ ./exp.sh query graph --format column --header \
       --exec 'MATCH (s:`setup:juliaenv`)-[:used_by]->(:submit)-[:call]->(:julia)-[:call]->(r:run) RETURN s.id, r.app, r.procs, r.hostnames'
   s.id                                  r.app   r.procs  r.hostnames
   ------------------------------------  ------  -------  -------------
   018f27aa-4b1c-7d3e-8f0a-1b2c3d4e5f60  render  1        node07
   018f27aa-4b1c-7d3e-8f0a-1b2c3d4e5f60  render  2        node07,node08
   018f27aa-4b1c-7d3e-8f0a-1b2c3d4e5f60  render  1        node07

Because a ``setup:`` label contains a colon, it is quoted with backticks, and the
whole ``--exec`` is single-quoted so the shell leaves those backticks alone. Every
row shares the same ``s.id`` --- the one setup every job consumed --- and
each carries the placement of a distinct run (a few are shown here). Adapt it by changing the setup label
(``setup:<name>``), projecting other columns (any column of the ``runs`` table,
e.g. ``r.procs_per_node`` or ``r.native_cmd``), or extending the path one more hop
to the app that recorded the science metric ---
``-[:call]->(img:render) RETURN r.hostnames, img.inside``.

Step 7 --- ask your experiment in natural language
--------------------------------------------------

``query sql`` and ``query graph`` are precise, but they ask you to know the
schema and write the query. Knit can also put a language model in front of the
*same* records, so you can ask in plain English. Everything it does is
**read-only**: the model may inspect the interface and the recorded runs, but it
cannot run your commands or change anything.

First, point Knit at an OpenAI-compatible provider. Knit never stores your API
key --- you give it the *name* of the environment variable that holds the key, and
it reads that variable at call time:

.. code-block:: console

   $ export OPENAI_API_KEY=sk-...
   $ ./exp.sh ai init --api-key-env OPENAI_API_KEY --model o4-mini

That records only non-secret configuration (env-var names and defaults) in the
metadata table. ``--base-url`` defaults to ``https://api.openai.com/v1`` but can
point at any OpenAI-compatible endpoint, and the same settings can be given at
bootstrap with the ``--ai-*`` options (``bootstrap --ai-api-key-env
OPENAI_API_KEY --ai-model gpt-4o-mini``). Use ``--force`` to overwrite an existing
configuration.

**Open-ended questions, with** ``ai ask``. The AI model answers by calling Knit's own
read-only tools --- ``describe``, ``--help``, ``metadata show``, read-only SQL, and
a job's captured output --- so its answers are grounded in *this* experiment rather
than guessed:

.. code-block:: console

   $ ./exp.sh ai ask --question "which Julia constant produced the most interior points?"
   The render with c_re=-0.7, c_im=0.0 (the "San Marco" constant) had the most
   interior points (inside=119960), ahead of c_re=-0.391 (78043) and c_re=-1.0
   (74800).

Pass ``--verbose`` to stream each tool call and result to stderr and watch it
work. Because the tools are read-only, ``ai ask`` can describe and inspect the
experiment but never submit a job or write to the database.

**Auditable answers, with** ``ai query``, is narrower: it turns the question
into exactly *one* read-only SQL statement, runs it against Knit's database, and
prints the result in the sqlite output mode you choose. If the SQL errors, Knit
feeds the error back so the model can correct it (up to ``--max-iterations``):

.. code-block:: console

   $ ./exp.sh ai query --format column \
       --question "Show each render's constant and inside count, most interior first"
   c_re    c_im    inside
   ------  ------  ------
   -0.7    0.0     119960
   -0.391  -0.587  78043
   -1.0    0.0     74800
   -0.123  0.745   69456
   0.285   0.535   67424
   -1.25   0.0     34164
   -0.1    0.651   890

When you would rather review the query than trust it blindly, ``--sql-only``
prints the generated statement without running it --- handy for pasting into
``query sql`` yourself:

.. code-block:: console

   $ ./exp.sh ai query --sql-only \
       --question "Show each render's constant and inside count, most interior first"
   SELECT c_re, c_im, inside FROM render ORDER BY inside DESC;

Both commands need a configured provider and a reachable key; without one they
stop with a clear message pointing you back to ``ai init``. Provider setup,
scope, and limits are covered in :doc:`Basic Usage <../basic/index>`.

Step 8 --- inspect and manage what you have built
-------------------------------------------------

The experiment is complete: it builds its software, submits jobs, runs them in
parallel, records every run, and answers questions about the results. Before we
take it to a cluster, it is worth meeting the handful of builtin commands that let
you look around, retrieve outputs, and tidy up. None of them change the
experiment's code --- they all operate on the experiment you have already written,
and every one is a Knit builtin available in any experiment.

**Know the interface, with** ``describe`` **and** ``--help``. ``describe`` prints
the command tree --- every command with its parameters, types, defaults, and
outputs --- built purely from the registrations, so it runs without touching the
database or building anything. Narrow it to one command with ``--only``:

.. code-block:: console

   $ ./exp.sh describe --only submit:julia
   julia
   -----
     [job, user]  Render a Julia-set fractal as a submitted job.

     Options
     -------
       --help              Print this help message and exit.
       --width <value>     [default: '800'] Image width in pixels.
       --height <value>    [default: '600'] Image height in pixels.
       --c-re <value>      [default: '-0.8'] Real part of the Julia constant c.
       --c-im <value>      [default: '0.156'] Imaginary part of the Julia constant c.
       --max-iter <value>  [default: '1000'] Maximum iterations per pixel.
       --colormap <value>  [default: 'fire'] Palette: grayscale | fire | ocean.
       --output <value>    [default: 'fractal.png'] PNG file name, written in the job directory.

Bare, ``describe`` walks the whole tree; ``--format yaml`` or ``--format json``
give a machine-readable view (both carry the Knit version and the full typed
interface --- the same structure the AI tools in Step 7 read), ``--format
markdown`` produces a table you can drop into documentation, and
``--exclude-builtins`` hides Knit's own commands so you see only yours. The
per-command ``--help`` shows the same options focused on a single command
(``./exp.sh julia --help``), and the top-level ``./exp.sh --help`` lists the
entire tree.


**Revisit your jobs.** ``job list`` shows every job you have submitted with its
lifecycle state:

.. code-block:: console

   $ ./exp.sh job list
   id                                    job    state
   ------------------------------------  -----  ---------
   018f2a1b-9c3d-7e4f-8a1b-2c3d4e5f6a7b  julia  completed
   018f3b2c-0d4e-7f5a-9b2c-3d4e5f6a7b8c  julia  completed
   018f4c3d-1e5f-7a6b-0c3d-4e5f6a7b8c9d  julia  completed

Filter it with ``--status running``, ``--types julia``, or ``--setup mympienv``,
and add ``--json`` for scripting. ``job status --id <uuid>`` prints one job's
state, and ``job wait --id <uuid>`` blocks until a job reaches a terminal state
(this is what ``submit --wait`` does for you).

Step 3 used ``job show stdout`` to read a job's captured output; the same command
also retrieves its standard error and the exact batch script Knit generated and
handed to the scheduler:

.. code-block:: console

   $ ./exp.sh job show script --id 018f2a1b-9c3d-7e4f-8a1b-2c3d4e5f6a7b
   #!/bin/bash
   source .../setups/mympienv/.activate.sh
   exec ./exp.sh submit --setup mympienv -- julia ...

On a laptop that script just activates the setup and runs the job in the
background; on a cluster the very same command shows the ``#SBATCH`` / ``#PBS``
directives Knit filled in --- which is exactly what the next step introduces.

When a job is no longer wanted, or you want to run it again, two commands close
the loop: ``job cancel --id <uuid>`` stops a running job, and
``job resubmit --id <uuid>`` re-runs a job reusing its recorded parameters ---
repeating a run without retyping its arguments.

**Record notes, with** ``metadata``. Knit keeps a small key/value table for
experiment-level facts. Store your own and read one back:

.. code-block:: console

   $ ./exp.sh metadata store --key note --value "week-1 parameter sweep"
   $ ./exp.sh metadata load --key note
   week-1 parameter sweep

``metadata show`` lists everything in the table. Your own keys sit alongside the
``__…__`` keys Knit records at bootstrap (the project name, the detected scheduler
and launcher, queue and walltime defaults), so this is also where you can see how
Knit configured itself. Because it is an ordinary table, it is queryable like
anything else --- ``query sql --exec "SELECT * FROM metadata"`` --- and ``ai``
can read it too. Use ``--force`` with ``metadata store`` to overwrite an existing
key.

**Inspect the Spack environment, with** ``spack``. The setup provisioned its
dependencies with Spack; the ``spack`` wrapper runs any Spack command inside that
same provisioned environment, so you can confirm what got built or examine a
concrete spec:

.. code-block:: console

   $ ./exp.sh spack find
   $ ./exp.sh spack spec cmake

Arguments after ``spack`` are forwarded verbatim, so anything Spack understands
works here.

With these in hand you can inspect, retrieve, and manage everything the experiment
records. The one thing left is to run it where it is meant to run --- a real
cluster --- which is the final step.

Step 9 --- move to a real HPC machine
-------------------------------------

Everything so far ran on a laptop. Moving to a supercomputer changes **nothing in
the experiment script**: the ``juliaenv`` setup, the ``julia`` job, and the
``render`` app are all unchanged. What differs is the machine underneath ---
its scheduler (PBS or Slurm instead of a background process), its MPI launcher,
and how many nodes you can ask for. Knit captures those machine facts once, at
bootstrap, and every ``submit`` afterwards uses them. This step shows how.

**Start from a machine profile.** A *profile* is a small, versioned JSON
description of a known HPC system --- its scheduler, its launcher, its default
queue and per-queue limits, and its hardware (cores and GPUs per node). Knit
ships profiles for several machines and serves them from its repository. List
what is available:

.. code-block:: console

   $ ./exp.sh profile list --hidden
     anl/aurora            [github, hidden] ALCF Aurora — Intel Xeon Max, 208 cores + 6× Intel GPU Max per node
     anl/improv            [github, hidden] LCRC Improv — 2× AMD EPYC 7713, 128 cores per node (CPU-only)
     anl/polaris           [github, hidden] ALCF Polaris — HPE Cray EX, 32 cores + 4× NVIDIA A100 per node
     nersc/perlmutter/cpu  [github, hidden] NERSC Perlmutter (CPU nodes) — HPE Cray EX (Slingshot); 2× AMD EPYC 7763, 128 cores
     nersc/perlmutter/gpu  [github, hidden] NERSC Perlmutter (GPU nodes) — HPE Cray EX (Slingshot); 1× AMD EPYC 7763 (64 cores) + 4× NVIDIA A100
     ornl/frontier         [github, hidden] ORNL Frontier — HPE Cray EX, 64 cores + 8× AMD MI250X per node

Each line is a profile name, a bracketed tag for where it came from, and the
profile's one-line description. The tag is ``github`` for the profiles Knit ships;
a site can add its own under ``/etc/knit/profiles``, which show up as ``admin``.
Profiles still being validated on their machine ship *hidden* and are left out of
a plain ``profile list`` --- ``--hidden`` reveals them and tags them ``hidden``,
which is why every profile above carries that tag. Profile names have two or more
path segments (``nersc/perlmutter/cpu`` names a specific node type). Inspect one
before you commit to it --- before bootstrap you pass the spec explicitly:

.. code-block:: console

   $ ./exp.sh profile show --profile anl/polaris
   {
       "description": "ALCF Polaris — HPE Cray EX, 32 cores + 4× NVIDIA A100 per node",
       "scheduler": {
           "type": "pbs",
           "command": "qsub",
           "default_queue": "prod",
           "queues": {
               "prod":  { "min_nodes": 10, "max_nodes": 496, "min_walltime": "00:05:00", "max_walltime": "24:00:00" },
               "debug": { "min_nodes": 1,  "max_nodes": 2,   "min_walltime": "00:05:00", "max_walltime": "01:00:00" }
           }
       },
       "launcher": { "type": "pals", "command": "mpiexec" },
       "hardware": { "cores_per_node": 32, "gpus_per_node": 4 }
   }

The output is abbreviated here: a full profile also lists the ``modules`` to load
and a ``spack`` block whose ``externals`` name vendor packages (the system MPI,
for instance) that a setup's Spack environment reuses instead of rebuilding. A
profile spec can also be a URL or a path to a local JSON file, so a site or a
collaborator can hand you one that is not in the Knit repository.

**Bootstrap under the profile.** On the cluster, bootstrap the experiment and
point it at the profile. This freezes the profile's facts into the experiment's
metadata and records the allocation you will charge jobs to:

.. code-block:: console

   $ ./exp.sh bootstrap --profile anl/polaris --account MyAllocation

The profile pre-populates the scheduler (``pbs``), the launcher (``pals``), the
default queue (``prod``), and the per-node core and GPU counts, so you do not have
to spell any of them out. If you omit ``--profile``, Knit still detects the
scheduler and launcher from what is on ``PATH`` (``--scheduler auto`` and
``--launcher auto`` are the defaults) --- a profile simply makes the choice
explicit and adds the queue limits and hardware facts autodetection cannot know.
Either way, the resolved values land in the ``__scheduler__``, ``__launcher__``,
and ``__account__`` metadata keys you met in Step 8, and ``profile show`` (no
spec now) prints the profile frozen at bootstrap.

**Build the setup on the machine.** The setup is where the software is compiled,
so it must run once on the cluster to rebuild ``julia-fractal`` with *that*
machine's compilers and MPI:

.. code-block:: console

   $ ./exp.sh setup --name mympienv -- juliaenv

Because the machine now advertises its own launcher (PALS), that launcher is used
in preference to the Spack-built one the setup provides --- exactly the precedence
described in Step 4. The setup's ``knit_provides_launcher`` remains the laptop
fallback; on a real machine it steps aside.

**Submit across an allocation.** The ``submit`` command is the same one you have
used all along; a cluster just gives its scheduler-facing options something real
to do:

.. code-block:: console

   $ ./exp.sh submit --nodes 2 --queue debug --walltime 00:30:00 --wait \
       -- julia --c-re -0.8 --c-im 0.156
   018f5d4e-2f6a-7b7c-1d4e-5f6a7b8c9d0e
   $ ./exp.sh job show stdout --id 018f5d4e-2f6a-7b7c-1d4e-5f6a7b8c9d0e
   The job is running on hosts: x3006c0s1b0n0, x3006c0s1b1n0
   Number of grid points within the set: 181
   inside=181

``--nodes 2`` allocates two whole nodes; ``--queue`` and ``--walltime`` override
the profile's defaults for this one submission (leave them off and the profile's
``prod`` queue is used, an unset ``--walltime`` defaulting to that queue's
``max_walltime``). Knit does not enforce a queue's node or walltime limits ---
the scheduler is the sole authority on those; the profile records them only for
reference. The account you gave at bootstrap is reused
automatically, so you do not retype it --- override it per-submit with
``--account`` (the allocation charged, ``#PBS -A`` / Slurm ``--account``) or
``--project`` (a project tag, ``#PBS -P`` / Slurm ``--wckey``) when you need to.
For GPU nodes, ``--gpus-per-node`` requests accelerators. Knit allocates whole
nodes exclusively and fills the scheduler directives (``#PBS`` or ``#SBATCH``,
the ones ``job show script`` reveals) from the profile and these options.

The job body itself is untouched. It still launches one rank per node with
``knit run --procs "$(knit_job_nodecount)" --procs-per-node 1 -- render …``, so on
this two-node allocation ``knit_job_nodecount`` is 2 and PBS/PALS places one rank
on each node --- the same code that launched a single rank on your laptop.

**That is the whole point.** The experiment you wrote on a laptop --- one script,
its setup, its job, its app, its queries --- moves to Polaris, Aurora, or Frontier
by changing only the profile you bootstrap with. No line of the experiment refers
to a scheduler, a launcher, a node count, or a queue; those live in the machine's
profile and in the options you pass at submit time. Write once, reproduce
anywhere.

That completes the tutorial. You have built a portable, self-provisioning,
fully-recorded HPC experiment from an empty directory. To go deeper on any piece
--- the recording and provenance model, setups and Spack, parallel placement,
querying, or the AI tools --- continue to :doc:`Basic Usage <../basic/index>`.

The complete experiment
-----------------------

Here is the whole thing in one file. Save it as ``exp.sh`` next to a copy of
``knit.sh``, make it executable (``chmod +x exp.sh``), and you have the finished
experiment this tutorial built:

.. literalinclude:: ../_code/julia_full.sh
   :language: bash

To run it from scratch:

.. code-block:: console

   $ ./exp.sh bootstrap # on a laptop; add --profile <machine> --allocation <alloc> on a cluster
   $ ./exp.sh setup --name mympienv -- juliaenv
   $ ./exp.sh submit --setup mympienv --wait -- julia --c-re -0.8 --c-im 0.156
   $ ./exp.sh aggregate

The first three commands provision, build, and run; ``aggregate`` totals the
``inside`` metric across every image you have rendered. Submit ``julia`` again
with different constants, on more nodes, or on another machine --- the script
never changes.
