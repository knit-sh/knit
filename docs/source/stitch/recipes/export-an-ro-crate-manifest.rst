..
   title: Export an RO-Crate manifest
   categories: bundle
   order: 30
   description: Describe the experiment's provenance as a standard RO-Crate / Process Run Crate manifest, embedded in a bundle with --ro-crate or emitted alone with knit export ro-crate.
   apis: bundle, export:ro-crate

`RO-Crate <https://www.researchobject.org/ro-crate/>`_ is a standard way to
package research data with machine-readable metadata. Knit generates an
``ro-crate-metadata.json`` from the recorded provenance --- one ``CreateAction``
per recorded run, wired to its inputs and outputs, following the RO-Crate 1.1 /
Process Run Crate profile --- so a bundle is also a self-describing,
FAIR-friendly research object.

Add the manifest to a bundle (see *Make a shippable bundle*) with ``--ro-crate``.
It is written at the archive root and describes exactly the packed files, so
``--ro-crate --zip`` yields a crate ready for Zenodo or WorkflowHub:

.. code-block:: console

   $ ./exp.sh bundle --ro-crate --zip --output montecarlo-pi.zip

To inspect or regenerate the manifest **alone**, with no archive and no copied
files, use ``knit export ro-crate``. It describes the experiment's on-disk files
by their current relative paths. ``--output`` defaults to
``./ro-crate-metadata.json``; ``--output -`` writes to stdout for a pipe:

.. code-block:: console

   $ ./exp.sh export ro-crate
   $ ./exp.sh export ro-crate --output - | jq '.["@graph"] | length'

Both entry points share one generator and the same prerequisites as ``bundle``:
a bootstrapped experiment (the manifest is built from ``knit.db``), read-only,
recording nothing. The ``--no-*`` and ``--include-*`` choices that decide what a
bundle contains also decide which entities the embedded manifest can reference:
it describes exactly what the bundle carries, no more.
