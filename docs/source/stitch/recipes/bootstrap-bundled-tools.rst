..
   title: Force building the bundled tools from source
   categories: bootstrap
   order: 80
   description: Build sqlite/jq from source instead of symlinking the system copies.
   apis: bootstrap

By default ``bootstrap`` symlinks the system ``sqlite3`` and ``jq`` when they are
available, and only builds or downloads its own copy when they are missing. Force
Knit to provision its own instead --- for a pinned, reproducible toolchain
independent of what the host happens to ship --- with ``--ignore-system-sqlite``
and ``--ignore-system-jq``:

.. code-block:: console

   $ ./exp.sh bootstrap \
       --ignore-system-sqlite \
       --ignore-system-jq

``--ignore-system-sqlite`` builds SQLite from source; ``--ignore-system-jq``
downloads a ``jq`` binary. Either way the tool lands under ``.knit/`` and is used
in preference to any system copy.
