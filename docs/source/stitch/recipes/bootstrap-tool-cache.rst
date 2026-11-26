..
   title: Reuse provisioned tools across bootstraps with the tool cache
   categories: bootstrap
   order: 85
   description: Cache the built sqlite/jq/transpiler/pilotd under ~/.cache/knit so re-bootstrapping is offline and free.
   apis: bootstrap

By default ``bootstrap`` builds its own ``sqlite3`` from source and downloads
``jq``, the ``knit-cypher-to-sql`` transpiler, and ``knit-pilotd`` (see *Use the
host's sqlite/jq instead of the bundled copies*). Doing that from scratch for
every fresh ``.knit/`` is slow, and a hard stop when the host is offline or
rate-limited.

Knit caches these four tools once, in a shared, per-user cache, and installs from
it on every later bootstrap. The cache lives under
``${XDG_CACHE_HOME:-~/.cache}/knit/tools`` --- a sibling of the plugin cache ---
and holds two layers: the downloaded sources (so a rebuild skips the download)
and the built binaries (so a re-provision skips the compile and just copies the
tree into ``.knit/``). A built-binary entry is keyed by tool version, platform,
and C toolchain, so it is only ever installed on a matching host; a cached binary
that fails to run is discarded and rebuilt.

The cache is automatic --- the first bootstrap populates it, and the next one is
fast:

.. code-block:: console

   $ ./exp.sh bootstrap          # builds the tools, fills the cache
   $ rm -rf .knit
   $ KNIT_OFFLINE=1 ./exp.sh bootstrap   # reinstalls from the cache, no network

``KNIT_OFFLINE=1`` forbids every download, so the second bootstrap can only
succeed by installing from the warm cache. This is the minimal re-provisioning a
reproducer runs after extracting a bundle, whose pruned ``.knit/`` ships the
database but not the tools.

To bypass the cache --- a host where ``~/.cache`` is unwritable, shared in a way
you distrust, or holding a bad entry --- set ``KNIT_TOOL_CACHE=0``. Every tool is
then downloaded and built fresh and nothing is cached. Combining
``KNIT_TOOL_CACHE=0`` with ``KNIT_OFFLINE=1`` is a contradiction (no cache and no
network) and stops with an error.

The cache is a provisioning accelerator, not part of ``.knit/``: it is never
bundled, and ``--use-system-sqlite`` / ``--use-system-jq`` still bypass it by
symlinking the host's binaries.
