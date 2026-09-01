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
result Knit relocates and packages; the contrast between a checksummed file
output that stays put and an artifact that is collected is the point of Step 5.

.. note::

   The directory pair mirrors the file pair. ``directory`` is checked like
   ``file`` --- same direction-aware existence check, with the checksum taken over
   the tree's contents --- and ``path`` is its unchecked counterpart, the way
   ``filename`` is for ``file``. Reach for ``directory`` when an output is a tree
   rather than a single file, and for ``path`` when you only need to *name* one.
