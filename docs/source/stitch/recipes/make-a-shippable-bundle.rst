..
   title: Make a shippable bundle
   categories: bundle
   order: 10
   description: Pack the whole experiment into one relocatable archive with knit bundle, ready to send to a collaborator or deposit in a repository.
   apis: bundle

``knit bundle`` packs the current experiment into a single archive that unpacks
anywhere. Every path inside is relative to the experiment script at the archive
root, and symlinks that point outside the tree are dereferenced, so the tree
keeps working after a move --- the archive is self-contained.

.. code-block:: console

   $ ./exp.sh bundle
   [knit:info] Wrote bundle to montecarlo-pi-bundle.tar.gz

The default output is ``./<project>-bundle.tar.gz`` (the project name from the
``metadata`` table, falling back to the script name without ``.sh``). Choose the
path with ``--output``, and write a zip instead of a tarball with ``--zip`` (what
Zenodo and WorkflowHub commonly expect):

.. code-block:: console

   $ ./exp.sh bundle --output /tmp/pi.zip --zip

By default the archive carries the **code** (the script and ``knit.sh``), the
**provenance database** (a pruned ``.knit/knit.db``), the **job logs and
scripts**, the **setup manifests**, and the **declared artifacts** --- everything
needed to read what happened and re-run it. It leaves out what is bulky and
regenerable (the built Spack tree, the provisioned toolchain, fetched resources),
recording how to rebuild them instead. Drop a default group with ``--no-knit``,
``--no-db``, ``--no-job-logs``, ``--no-job-scripts``, or ``--no-artifacts``, and
opt bulky content in with ``--include-job-content``, ``--include-resources
<name,…>``, or ``--include-all-resources``.

Preview the contents before writing anything with ``--dry-run``, which prints the
planned files as a tree; add ``--list`` for a flat, root-relative list and
``--size`` to annotate each entry with its size and a total:

.. code-block:: console

   $ ./exp.sh bundle --dry-run --size

``knit bundle`` needs a bootstrapped experiment (it reads ``knit.db``) and is
read-only: it records nothing. To carry files Knit does not track, see *Declare
extra files to bundle*; to add a standard metadata manifest, see *Export an
RO-Crate manifest*.
