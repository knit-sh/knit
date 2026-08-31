..
   title: Update configuration by re-running bootstrap
   categories: bootstrap
   order: 100
   description: Re-run bootstrap to change settings in place without losing the database or runs.
   apis: bootstrap

``bootstrap`` is re-runnable. Run it again on an already-bootstrapped experiment
to update the configuration in place --- it keeps the ``.knit/`` database, the
provisioned tooling, and every recorded run. Only the options you **type**
change; every other setting keeps its stored value. So you can adjust one field
long after the first bootstrap:

.. code-block:: console

   $ ./exp.sh bootstrap --default-cpus-per-node 128

A bare re-``bootstrap`` with no options changes nothing and reports that there is
nothing to update.

Some changes are constrained to protect recorded work. You can relocate a path
(``--setup-path`` / ``--job-path`` / ``--resource-path``) only while it is empty
of its kind --- no user setup, no job, or no resource yet; otherwise Knit stops
rather than strand existing rows. Changing the machine ``--profile`` is not
supported yet. Re-provisioning a bundled tool (see
:ref:`stitch-bootstrap-bundled-tools` and
:ref:`stitch-bootstrap-pin-knit-graph`) also happens
here: a typed tool option that differs from the stored value rebuilds that tool.
