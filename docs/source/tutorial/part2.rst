Part II --- Refining the experiment
===================================

:doc:`Part I <part1>` built a complete experiment: a Spack-backed setup that
compiles ``julia-fractal``, a ``julia`` job that submits it, a ``render`` app
that launches it across MPI ranks, and the query, provenance, and AI surfaces on
top. It works end to end, on a laptop and on a supercomputer.

This second part returns to that *same* experiment and improves it, piece by
piece. It follows Part I's order, from setup to run, and each section takes one
part of the experiment you already understand and shows a Knit capability that
makes it cleaner, safer, or more reproducible. Each section shows the change
against the Part I code, and the finished Part II experiment is collected in
one file at the end.

.. _tutorial-resources:

Step 1 --- Resources: fetch the source instead of cloning it
------------------------------------------------------------

Part I's ``juliaenv`` setup clones the ``julia-fractal`` source in its body:

.. code-block:: bash

   git clone "https://github.com/knit-sh/julia-fractal-example.git" \
       "${KNIT_SETUP_PREFIX}/src"
   git -C "${KNIT_SETUP_PREFIX}/src" checkout "${ref}"

That clone is invisible to Knit. Nothing records which commit was used, and
every fresh build of the setup downloads the source again. A **resource**
fixes both problems: it is a named input that Knit fetches once, caches,
and records.

Declare the source as a resource. A resource has no body function.
One download decorator says where it comes from:

.. knit-code:: ../_code/julia_resource.sh
   :language: bash
   :start-after: # START resource
   :end-before: # END resource

``@with_git`` selects the git backend and pins a default ref; ``@with_local``
and ``@with_url`` are the other two backends. Fetch a named instance with the
``fetch`` dispatcher:

.. code-block:: console

   $ ./exp.sh fetch --name julia_src -- julia_code
   $ ./exp.sh fetch --name julia_src -- julia_code --ref main   # pin another ref

``fetch`` clones the repository once at its pinned ref into the ``resources``
directory, makes it read-only, records the resolved commit in the
``resource:julia_code`` table, and prints the on-disk path. Fetching is
idempotent by name: re-fetching ``julia_src`` from the same source does nothing.

Now the setup declares the resource it needs instead of cloning it:

.. knit-code:: ../_code/julia_resource.sh
   :language: bash
   :start-after: # START setup
   :end-before: # END setup

``@with_resource "src:julia_code"`` adds a ``--src`` option to the setup and
validates it *before* the body runs: the named instance must exist and be of
type ``julia_code``, or Knit stops and prints the exact ``fetch`` command to run
first. Knit also records a ``used_by`` edge from the resource to the setup, so
the provenance graph now ties each build to the source revision it consumed.
Inside the body, ``knit_resource_path`` turns the instance name into its
directory. Fetch first, then build against the fetched instance:

.. code-block:: console

   $ ./exp.sh fetch --name julia_src -- julia_code
   $ ./exp.sh setup --name mympienv -- juliaenv --src julia_src

.. note::

   **A resource is meant for an input artifact --- a dataset or a reference
   input --- not source code.** The better way to handle the ``julia-fractal``
   source is to make it a `Spack <https://spack.io/>`_ package and let the
   Spack-backed setup build it, exactly as the setup already builds ``cmake``,
   ``libpng``, and ``mpi``. We fetch the code repository as a resource here only
   because it is the input Part I already downloads by hand, so the improvement
   is easy to see side by side. Do not read this section as "clone your source
   with a resource" --- read it as "acquire your inputs once, and let Knit record
   them."

.. _tutorial-parameter-sets:

Step 2 --- Parameter sets: declare the shared parameters once
-------------------------------------------------------------

The ``julia`` job and the ``render`` app declare the *same* six parameters ---
``width``, ``height``, ``c-re``, ``c-im``, ``max-iter`` and ``colormap`` ---
because the job forwards them straight to the app. In Part I each command spells
them out in full, so the two lists must be kept in step by hand: change a default
in one place and forget the other, and the job and the app quietly disagree.

A **parameter set** removes the duplication. It is a named group of parameter
declarations with no command of its own, defined like a command --- open it,
declare parameters, close it --- but with no body:

.. knit-code:: ../_code/julia_params.sh
   :language: bash
   :start-after: # START pset
   :end-before: # END pset

Import the set into a command with ``@with_parameter_set``. It brings in every
parameter the set declares, exactly as if they had been written out at that
point. The job imports the shared six and keeps its own ``output`` parameter,
which the app does not share:

.. knit-code:: ../_code/julia_params.sh
   :language: bash
   :start-after: # START job
   :end-before: # END job

The app imports the same set. Its ``output`` parameter differs from the job's
--- here it is required, since the job supplies one absolute path per run
--- so it stays a per-command declaration:

.. knit-code:: ../_code/julia_params.sh
   :language: bash
   :start-after: # START app
   :end-before: # END app

The shared parameters now live in one place: edit a default or a description in
``julia-params`` and both the job and the app pick it up. ``describe`` and
``--help`` show the imported parameters just as if each command had declared them
directly --- the set is a definition-time convenience, invisible at the command
line.

A parameter set may be imported by any number of commands, and a command may
import more than one set. A **conflict is fatal**: if an imported parameter has
the same name as one the command already declares (or as one from another
imported set), Knit stops at registration time rather than let a silent
collision through. Keeping ``output`` out of ``julia-params`` is what lets the
job declare it optional and the app declare it required without a clash.

.. _tutorial-enums:

Step 3 --- Enums: make ``colormap`` a validated type
----------------------------------------------------

``colormap`` accepts only three palettes --- ``grayscale``, ``fire`` and
``ocean`` --- but in Part I it is typed ``string``, so nothing checks the value.
A wrong palette (``--colormap purple``) passes the command line, reaches
``julia-fractal``, and fails deep in the render, far from the typo. An **enum**
moves that check to the front. It is a named type with a fixed set of values,
declared once:

.. knit-code:: ../_code/julia_enum.sh
   :language: bash
   :start-after: # START enum
   :end-before: # END enum

With the type in hand, the shared parameter changes from ``colormap:string`` to
``colormap:colormap`` --- a single edit in the ``julia-params`` set from Step 2,
so the job and the app both pick it up. ``knit_enum_values`` builds the help text
from the same declaration, so the list of palettes in the description can never
drift from the type:

.. knit-code:: ../_code/julia_enum.sh
   :language: bash
   :start-after: # START pset
   :end-before: # END pset

Now a value outside the set is refused up front, before the body runs, with a
message that names the accepted values:

.. code-block:: console

   $ ./exp.sh julia --colormap purple
   [knit:fatal] Parameter --colormap of "julia" expects one of: grayscale, fire, ocean (got "purple").

The choices are also advertised, so a user does not have to guess them.
``describe`` inlines them next to the default, and ``--help`` shows them through
the description built with ``knit_enum_values``:

.. code-block:: console

   $ ./exp.sh describe --only submit:julia
   ...
       --colormap <value>  [default: 'fire', one of: grayscale, fire, ocean] Palette: grayscale, fire, ocean.
   ...

An enum is a definition-time type like the built-in ``integer`` or ``real``:
declare it once, name it on as many parameters as you like, and every command
that takes one of those parameters --- here both the job and the app, through the
shared set --- validates and advertises the same fixed set of values.

.. _tutorial-file-output:

Step 4 --- File output: record the PNG as a checksummed intermediate
--------------------------------------------------------------------

The ``render`` app produces a PNG, but Part I does not record it. Its ``output``
parameter is typed ``string``, which accepts any value and carries no meaning;
nothing checks that the file appears or captures what it contains. If a render
silently writes nothing, the row still looks fine.

Knit has a small family of path-shaped types that say more. They come in two
pairs --- one for a single file, one for a directory tree --- and each pair has a
**checked** member and an **unchecked** counterpart:

- ``file`` is checked; ``filename`` is its unchecked counterpart.
- ``directory`` is checked; ``path`` is its unchecked counterpart.

All four accept a non-empty string. The difference is what Knit does with the
value. A **checked** type (``file``, ``directory``) verifies the target exists
--- *direction-aware*, so an input must exist before the body runs and an output
must exist when it finishes --- and records a SHA-256 checksum of its content. An
**unchecked** type (``filename``, ``path``) only asserts the value is non-empty;
Knit never touches the filesystem for it. Use an unchecked type when a value
merely *names* a location, and a checked type when Knit should confirm and
fingerprint what is actually there.

Typing the app's input and its new output from this family puts each value in the
right category. Bind the produced PNG with ``knit_output``:

.. knit-code:: ../_code/julia_file.sh
   :language: bash
   :start-after: # START app
   :end-before: # END app

The ``output`` parameter is now a ``filename``: the destination the job hands in.
It must *not* be a ``file``, because a ``file`` input is checked for existence
*before* the body runs --- and the render has not written the PNG yet, so that
would fail every run. ``filename`` --- the unchecked counterpart of ``file`` ---
is exactly right for "somewhere to write." (The job types its own bare ``output``
name the same way.)

The ``image`` output, by contrast, is a ``file``. Because the value is a path to
a file that must exist when the app finishes, Knit does two things Part I did
not. First, it enforces existence: a render that produced no file is now caught
at once, with a fatal error, not discovered later. Second, it records the
content: it hashes the file with SHA-256 and writes the digest into a companion
``image_checksum`` column that it adds to the ``render`` table automatically.
``describe`` shows both the output and its synthesized column:

.. code-block:: console

   $ ./exp.sh describe --only run:render
   ...
     Outputs
     -------
       inside          [integer, default: '0'] Grid points inside the set (recorded by rank 0).
       image           [file, default: ''] The PNG this render produced (checksummed intermediate).
       image-checksum  [string, default: ''] SHA-256 checksum of "image", recorded automatically.

The checksum lets a reproducer confirm that a re-run produced byte-for-byte the
same image. Hashing a large file has a cost, so a file output can opt out of the
digest with ``--no-checksum`` on the declaration; the existence check still
applies (it is a property of the type), only the ``image_checksum`` column is
dropped.

The PNG stays exactly where the job wrote it, in the job directory. A file
output does not move the file or copy it anywhere --- it records a path and a
digest against the row that produced it. That makes the image a **checksummed
intermediate**: tracked, verifiable, and tied to its render, but local to the
run. The next section introduces its counterpart, an **artifact**, which is a
result Knit relocates and records under a common root; the contrast between a
checksummed file output that stays put and an artifact that is collected is the
point of Step 5.

.. note::

   The directory pair mirrors the file pair. ``directory`` is checked like
   ``file`` --- same direction-aware existence check, with the checksum taken over
   the tree's contents --- and ``path`` is its unchecked counterpart, the way
   ``filename`` is for ``file``. Reach for ``directory`` when an output is a tree
   rather than a single file, and for ``path`` when you only need to *name* one.

.. _tutorial-results-artifacts:

Step 5 --- Results and artifacts: record the table as a result artifact
-----------------------------------------------------------------------

Part I's ``aggregate`` command is read-only bookkeeping. It is marked
``@without_provenance``, so it records nothing: it runs two ``knit query sql``
counts, prints a one-line summary, and leaves no trace that it ran or what it
found. The numbers scroll past and are gone.

This section turns ``aggregate`` into the command that produces the experiment's
headline result. Two changes do it: drop ``@without_provenance`` so the command
records its own row and provenance, and declare the table it builds as an
**artifact**:

.. knit-code:: ../_code/julia_artifact.sh
   :language: bash
   :start-after: # START aggregate
   :end-before: # END aggregate

Two Knit surfaces are new here.

**A graph query builds the table.** Part I read the ``render`` table with
``knit query sql``. Here ``knit query graph`` runs a **Cypher** query against the
same provenance database, with ``--format csv`` so the result is a data table
ready to write to a file. The pattern ``(r:run)-[:call]->(img:render)`` walks the
provenance graph: a node label is a command or table name, ``-[:call]->`` is the
edge Knit records when one command launches another, so the query visits every
``render`` reached through the ``run`` that launched it. ``RETURN ... AS`` names
the projected columns, and ``--header`` writes them as the CSV header row. (The
``run`` row and the ``render`` row have distinct ids; the graph edge, not a shared
key, is what ties them together, which is exactly what a graph query is for.)

**An artifact records the result, with a kind.** An artifact has a physical
*type* --- ``file`` or ``directory`` --- and, optionally, a semantic **kind**: a
label backed by one physical type that says what the file *means*. Declared once
at the top level, ``insidecsv`` marks a file as *the inside-metric table*:

.. knit-code:: ../_code/julia_artifact.sh
   :language: bash
   :start-after: # START kind
   :end-before: # END kind

``@with_output_artifact "table:insidecsv" ... --result`` then declares that the
command produces an artifact of that kind and that it is the **result** --- what
the experiment was for. Inside the body, ``knit_artifact_dir`` gives the artifacts
root, and ``knit_artifact "table" "inside.csv"`` binds the file that was written
there. The kind is recorded in the artifacts row and ``describe`` shows it (not
the bare physical type) in the command's own section, flagged as a result:

.. code-block:: console

   $ ./exp.sh describe --only aggregate
   ...
     Artifacts
     ---------
       table  [insidecsv, result] Per-render inside metric, one row per image (CSV).

An artifact is not a file output. The distinction is the point of this section:

- A **file output** (Step 4) is a *column on the producing command's own table*.
  It records a path and a checksum, and the file stays exactly where it was
  written --- the PNG never moves. It is a tracked intermediate, local to the run.
- An **artifact** is a *row in the framework-owned* ``artifacts`` *table*, a node
  of its own, linked to the invocation that made it by a ``produced`` edge. Its
  path is stored relative to the artifacts root --- never an absolute machine path
  --- so the whole ``artifacts/`` tree can be moved or shipped and the records
  still resolve. That relocatable, self-describing entry is the durable record of
  what the run produced. ``--result`` changes nothing about how the artifact is
  stored; it is only a marker that flags the entry as a headline output, so
  ``describe`` and other surfaces can draw attention to it.

Knit always checksums an artifact (there is no ``--no-checksum`` for it), and
each artifacts-relative path is **write-once**: binding ``inside.csv`` twice is a
fatal error, so a re-run either uses a fresh name or removes the old entry first
--- :ref:`Step 7 <tutorial-remove>` erases recorded entities and their artifacts.

The before/after on this one command captures the whole idea. In Part I,
``aggregate`` recorded nothing --- no row, no result, no file. In Part II the same
command records a row, marks a result, writes a relocatable table, and leaves a
``produced`` edge from that row to the table's node. That edge is queryable like
any other. To find which command produced a given artifact, walk the
``produced`` edge backwards:

.. code-block:: console

   $ ./exp.sh query graph --format column --header --exec \
       "MATCH (t)-[e:produced]->(a:artifacts)
          WHERE a.name = 'table' RETURN e.source_name, a.path, a.checksum"

**Consume the artifact.** A result is only half a lineage until something reads
it. Part II adds a ``report`` command that consumes the table ``aggregate``
produced and names the render with the largest inside metric:

.. knit-code:: ../_code/julia_artifact.sh
   :language: bash
   :start-after: # START consume
   :end-before: # END consume

``@with_input_artifact "table:insidecsv"`` registers a required parameter whose
value is the artifacts-relative path of a recorded artifact of kind
``insidecsv``. Before the body runs, Knit resolves the path to its artifacts row
and refuses the run when the value is empty, when no artifact is recorded there,
or when the recorded kind is not ``insidecsv`` --- so ``report`` never reads the
wrong kind of input. ``--verify-checksum`` adds one more guard: it re-hashes the
bytes and refuses a table that changed since it was produced, against the digest
``aggregate`` recorded. In the body, ``knit_input_artifact_path`` turns the stored
path into the on-disk file to read. Run it against the table by its
artifacts-relative path:

.. code-block:: console

   $ ./exp.sh report --table inside.csv
   peak inside metric: 512345

Consuming the artifact records a ``used_by`` edge **from the artifact's row to
``report``**, the mirror of the ``produced`` edge ``aggregate`` left. The two
edges meet at the same artifact node, so one query walks the whole chain
``aggregate --produced--> table --used_by--> report``:

.. code-block:: console

   $ ./exp.sh query graph --format column --header --exec \
       "MATCH (p)-[:produced]->(a:artifacts)-[:used_by]->(c)
          WHERE a.name = 'table'
          RETURN p.source_name, a.kind, c.target_name"

The experiment now has a result that outlives the run --- a checksummed,
relocatable table --- and a lineage that runs both ways from it: back to the
command that built it and every render that went into it, and forward to every
command that read it.

.. _tutorial-prepare:

Step 6 --- Prepare: build a batch of runs, release them on your terms
---------------------------------------------------------------------

Part I's sweep fired one job at a time::

   $ ./exp.sh submit --setup mympienv --wait -- julia --c-re -0.123 --c-im 0.745
   $ ./exp.sh submit --setup mympienv --wait -- julia --c-re -1.0   --c-im 0.0
   ... five more ...

``submit`` does two things at once: it *builds* the job --- validates it, creates
its directory, writes the batch script, records the row --- and then *dispatches*
it to the scheduler. Fusing the two is fine for one job, but a sweep wants them
apart: describe every run up front, then release the runs at a rate you control
(a few at a time, a cron tick, or a loop that keeps *N* in flight). ``prepare``
does exactly the build half.

**Prepare one job.** ``prepare`` mirrors ``submit`` argument-for-argument over
the same job registry --- minus ``--wait``, since nothing is dispatched --- and
adds a ``--group`` label you can filter on later. It records the ``jobs`` row in a
new ``prepared`` state and stops before the scheduler:

.. code-block:: console

   $ ./exp.sh prepare --setup mympienv --group julia-sweep -- julia --c-re -0.123 --c-im 0.745
   018f9c3a-7b2e-7c41-9d0a-1f2e3d4c5b6a

The whole submission spec --- setup, nodes, walltime, queue, and the job's own
arguments --- is frozen at prepare time and baked into the batch script, so
releasing the job never re-opens those options. The UUID it prints is the same
stable identifier ``submit`` would have given it.

**Prepare the whole sweep from a plan.** Typing one ``prepare`` per constant is
no better than typing one ``submit`` per constant. ``prepare from`` reads the
whole batch as a JSON plan --- from a file with ``--file``, or on stdin --- and
prepares each entry as if you had run ``prepare -- julia …`` by hand. Part I's
seven-line sweep becomes one plan:

.. code-block:: json

   {
     "group": "julia-sweep",
     "defaults": { "setup": "mympienv" },
     "jobs": [
       { "job": "julia", "args": { "c-re": -0.123, "c-im": 0.745  } },
       { "job": "julia", "args": { "c-re": -1.0,   "c-im": 0.0    } },
       { "job": "julia", "args": { "c-re": -0.391, "c-im": -0.587 } },
       { "job": "julia", "args": { "c-re": 0.285,  "c-im": 0.535  } },
       { "job": "julia", "args": { "c-re": -0.7,   "c-im": 0.0    } },
       { "job": "julia", "args": { "c-re": -1.25,  "c-im": 0.0    } },
       { "job": "julia", "args": { "c-re": -0.1,   "c-im": 0.651  } }
     ]
   }

``group`` tags every prepared job; ``defaults`` is a field map merged **under**
each entry (so ``--setup mympienv`` is written once, not seven times); ``jobs``
lists the entries. Within an entry, ``args`` is the job's own arguments (an object
``{"c-re": -1.0}`` becomes ``--c-re -1.0``), and any other key is a submission
option (``nodes``, ``walltime``, ...), exactly as on the ``prepare`` command line.
Feed the plan on stdin or from a file:

.. code-block:: console

   $ ./exp.sh prepare from --file sweep.json
   $ ./exp.sh prepare from < sweep.json

The whole plan is validated before any job is prepared, so a malformed plan --- an
unknown key, a missing ``job`` --- leaves nothing half-prepared. The jobs are
prepared in plan order.

**Vary a submission option with a matrix.** A ``jobs`` entry may be a ``matrix``
block instead of a concrete entry. It expands to one prepared job per combination:
the cartesian product of its ``axes``, minus every ``exclude``, plus each
``include``. An ``args`` axis varies the job's own arguments; a bare axis key
varies a submission option. To render a few constants at both one and two nodes,
give an ``args`` axis and a ``nodes`` axis:

.. code-block:: json

   { "matrix": {
       "job": "julia",
       "axes": {
         "args":  [ { "c-re": -0.123, "c-im": 0.745 }, { "c-re": -1.0, "c-im": 0.0 } ],
         "nodes": [ 1, 2 ]
       }
   } }

That single block expands to four prepared jobs (two constants times two node
counts).

**Inspect the batch.** Prepared jobs can be listed as follows.

.. code-block:: console

   $ ./exp.sh job list --status prepared

**Release on your terms.** Two ``submit`` subcommands hand prepared jobs to the
scheduler. ``submit prepared --id`` releases one specific job; ``submit next``
releases the oldest prepared job, optionally narrowed by ``--type`` (the job name)
or ``--group``. The claim is atomic, so concurrent releasers never double-submit a
row, and ``submit next`` returns non-zero when nothing matches --- so a
fill-the-queue loop drains a group and stops on its own:

.. code-block:: console

   $ ./exp.sh submit prepared --id 018f9c3a-7b2e-7c41-9d0a-1f2e3d4c5b6a --wait
   $ while ./exp.sh submit next --group julia-sweep --wait; do :; done

Releasing advances the *same* row through ``prepared`` --- ``submitted`` ---
``running`` --- ``completed``; the UUID never changes, so the job you prepared and
the job that ran are one recorded entity, and ``knit query`` sees the whole group
at once:

.. code-block:: console

   $ ./exp.sh query sql --format column --header --exec \
       "SELECT id, job, state, \"group\" FROM jobs WHERE \"group\" = 'julia-sweep'"

Preparing separates *describing* a batch of runs from *releasing* them: the plan
is the durable description, and the release policy is yours.

.. _tutorial-remove:

Step 7 --- Remove: erase recorded entities and their dependents
----------------------------------------------------------------

Sooner or later you want to take something back out of the experiment: a resource
you fetched, a setup you built, a job or a plain command you ran, an artifact one
of them produced. ``knit remove`` erases any of these. The catch is that a
recorded entity is never isolated --- Part I built a provenance graph tying it all
together, and the earlier steps of Part II added edges of their own. A job *used*
a setup; a run *belongs to* a job; a command *produced* an artifact. Deleting one
row without regard for those edges would leave the graph dangling, its records
pointing at things that no longer exist.

``knit remove`` is provenance-aware, so it never does that. It erases the entity
you name **and everything recorded downstream of it** --- the rows it called, the
runs and app invocations under them, and the artifacts they produced --- in one
transaction. What the entity *used* (a job's setup, a setup's resource) is left
alone: those edges point *into* it, not out of it, so removing a job never takes
its setup with it.

**Preview before you delete.** Every ``remove`` prints an itemized report of
exactly what it will erase, and ``--dry-run`` prints that report and stops ---
nothing is touched. Point it at one finished job by its id:

.. code-block:: console

   $ ./exp.sh remove job --id 018f9c3a-7b2e-7c41-9d0a-1f2e3d4c5b6a --dry-run
   The following will be permanently erased:

     Data rows (4):
       job      julia                018f9c3a-...  (state: completed)
       job      julia                01926b7a-...  (body row)
       run      render               01926b7c-...
       app      render               01926b7d-...

     Provenance edges (5):
       submit 018f9c3a-... --call--> julia 01926b7a-...
       ...

     Directories and artifacts removed (1):
       jobs/018f9c3a-...

The ``render`` app writes ``fractal.png`` into the job directory, so the PNG goes
with ``jobs/018f9c3a-...`` above; the report does not list it a second time. A
plain output written *outside* every removed directory would appear under a
separate "Left on disk" heading, and so would an artifact kept by
``--keep-artifacts`` (described below).

**Delete, with a confirmation.** Drop ``--dry-run`` and ``remove`` prints the same
report, then prompts before touching anything:

.. code-block:: console

   $ ./exp.sh remove job --id 018f9c3a-7b2e-7c41-9d0a-1f2e3d4c5b6a
   The following will be permanently erased:
   ...
   Erase these? [y/N]

Answer ``y`` to proceed; anything else aborts, untouched. Pass ``--yes`` to skip
the prompt for a script or a non-interactive shell.

**Prune the batch by group.** The ``--group`` selector names the whole
``julia-sweep`` batch Step 6 prepared, so one command erases all of it:

.. code-block:: console

   $ ./exp.sh remove job --group julia-sweep --dry-run   # preview the whole batch
   $ ./exp.sh remove job --group julia-sweep --yes

A live job is never erased out from under you: a job still ``prepared``,
``submitted``, or ``running`` is refused, with a pointer to ``job cancel``. Cancel
it, or let it finish, then remove it. Only a ``completed`` or ``killed`` job --- a
job that is truly done --- can be erased.

**Remove a setup and rebuild.** Part I treated a setup as write-once: with no way
to delete one, the advice was to give each rebuild a fresh name and let the old
ones pile up. That constraint is gone. Removing a setup cascades *downward* to
every job that used it --- and each job's runs and renders --- in one step, while
the fetched ``julia_code`` resource above it stays put:

.. code-block:: console

   $ ./exp.sh remove setup --name mympienv --dry-run   # preview the cascade
   $ ./exp.sh remove setup --name mympienv --yes

Now ``setup --name mympienv -- juliaenv`` builds a clean one against the same
resource. Retire and rebuild, rather than accumulate ``mympienv``, ``mympienv2``,
``mympienv3`` forever.

**Erase a whole lineage.** An artifact cannot be removed on its own: its producer
is kept, so deleting just the file would dangle the ``produced`` edge, and Knit
refuses with a hint. ``--from-root`` widens the erase set to the *entire*
call/produced lineage the artifact belongs to --- up to the root and back down ---
so the producing command and the artifact go together:

.. code-block:: console

   $ ./exp.sh remove artifact --path inside.csv --from-root --yes

**Keep the files, prune the records.** Two flags stop ``remove`` short of the
disk, at two scopes. ``--keep-artifacts`` erases the rows and edges and still
removes the job, setup, and resource directories, but leaves the recorded
**artifact** entries under ``artifacts/`` in place, each listed under "Left on
disk"; use it to reclaim the database while keeping the results a run produced.
``--keep-files`` goes further: it erases the rows and edges only and makes **no**
filesystem change at all --- every directory, artifact, and plain output stays,
each listed under "Left on disk"; use it to prune the provenance while leaving
the whole on-disk tree untouched.

The complete experiment (Part II)
---------------------------------

Here is the whole refined experiment in one file. It is the Part I script with
every Part II change from Steps 1--5 folded in: the git resource feeding the
setup, the shared parameter set, the ``colormap`` enum, the app's checksummed
file output, the fan-in that produces a result artifact of kind ``insidecsv``,
and the ``report`` consumer that reads it back. Steps 6 and 7 add no code ---
``prepare`` and ``remove`` are console workflows over this same script.
Save it as ``exp.sh`` next to a copy of ``knit.sh`` and make it executable
(``chmod +x exp.sh``):

.. knit-code:: ../_code/julia_full2.sh
   :language: bash

To run it from scratch:

.. code-block:: console

   $ ./exp.sh bootstrap # on a laptop; add --profile <machine> --allocation <alloc> on a cluster
   $ ./exp.sh fetch --name julia_src -- julia_code
   $ ./exp.sh setup --name mympienv -- juliaenv --src julia_src
   $ ./exp.sh submit --setup mympienv --wait -- julia --c-re -0.8 --c-im 0.156
   $ ./exp.sh aggregate
   $ ./exp.sh report --table inside.csv

``fetch`` acquires the source once and records its commit; ``setup`` builds
against that named instance; ``submit`` renders one image; ``aggregate`` writes
``inside.csv`` as a result artifact and records its own row; ``report`` consumes
that artifact by kind and records a ``used_by`` edge back to it. From here the
Part II workflows apply to this same script: :ref:`prepare <tutorial-prepare>` a
whole sweep and release it, then :ref:`remove <tutorial-remove>` what you no
longer need. Compare this file with :ref:`Part I's version <tutorial-full>` to
see, in one diff, what the refinements bought.
