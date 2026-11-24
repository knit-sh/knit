..
   title: Use the host's sqlite/jq instead of the bundled copies
   categories: bootstrap
   order: 80
   description: Symlink the system sqlite/jq with --use-system-* instead of the default self-contained build.
   apis: bootstrap

By default ``bootstrap`` provisions its own toolchain under ``.knit/`` --- it
builds ``sqlite3`` from source and downloads a ``jq`` binary --- so the install is
self-contained and reproducible, independent of what the host ships. This also
makes it portable to an HPC compute node, which often differs from the login
node: a symlink to a login-only binary would dangle there.

On a single machine where the system copies are known good, symlink them instead
--- a faster bootstrap, with no build or download --- with ``--use-system-sqlite``
and ``--use-system-jq``:

.. code-block:: console

   $ ./exp.sh bootstrap \
       --use-system-sqlite \
       --use-system-jq

Each flag symlinks the system tool into ``.knit/`` when it is on ``PATH``, and
falls back to the default build/download when it is not. Prefer the default on a
cluster; reach for ``--use-system-*`` only when the same binary is guaranteed on
every node your jobs run on.
