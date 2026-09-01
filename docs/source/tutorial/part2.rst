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
