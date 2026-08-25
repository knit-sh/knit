..
   title: Bootstrap an experiment
   categories: bootstrap
   order: 10
   description: Initialize an experiment's .knit/ directory before running any command.
   apis: bootstrap

Every experiment must be **bootstrapped once** before any other command runs.
``bootstrap`` creates the ``.knit/`` directory next to your script --- a small
SQLite database that records runs, plus the tools Knit relies on (it installs
``sqlite3``, ``jq``, and ``knit-graph`` locally, symlinking the system copies of
``sqlite3``/``jq`` when they are already available):

.. code-block:: console

   $ ./exp.sh bootstrap

Run ``bootstrap`` again to update the configuration in place --- it keeps the
database, the tooling, and every recorded run (see
:doc:`bootstrap-update-configuration`). To start over instead, remove the
``.knit/`` directory first. The remaining Bootstrap recipes cover the options
that pin project settings, paths, the scheduler and launcher, and the
provisioned tool versions.
