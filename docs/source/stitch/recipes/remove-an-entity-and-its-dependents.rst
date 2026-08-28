..
   title: Remove an entity and its dependents
   categories: cleanup
   order: 10
   description: Erase a setup, resource, job, run, or command by name, type, or id, cascading down the provenance graph to everything that used it.
   apis: remove:setup, remove:resource, remove:job, remove:run, remove:command, remove:artifact

``knit remove`` erases a recorded entity from the database together with the
rows, provenance edges, and on-disk directories that depend on it --- the safe,
provenance-aware alternative to leaving stale setups and runs to accumulate
forever. There is one subcommand per kind (``remove setup``, ``remove
resource``, ``remove job``, ``remove run``, ``remove app``, ``remove command``,
``remove artifact``), and each takes **exactly one** selector:

- ``--id <id>`` --- one row by its recorded id;
- ``--name <name>`` --- a setup / resource / job instance by its instance name;
- ``--type <type>`` --- every setup / resource / job of a type at once;
- ``--group <group>`` --- every job in a submission group (``remove job`` only);
- ``--path <path>`` --- an artifact by its artifacts-relative path (``remove
  artifact`` only).

.. code-block:: console

   $ ./exp.sh remove setup --name buildenv
   $ ./exp.sh remove job --id "$id"
   $ ./exp.sh remove resource --type dataset

By default remove cascades **downward**: it follows ``call`` and ``produced``
edges from the selection, and ``used_by`` edges *only outward from a provider*.
So removing a **provider** (a setup or a resource) also erases every consumer
that used it --- the jobs, their runs, and their artifacts. Removing a
**consumer** (a job) does the opposite: the setup and resource it used are left
in place, and only the ``used_by`` edge into the erased job is dropped.

remove prints an itemized report of exactly what it will erase and asks for
confirmation. Pass ``--yes`` to skip the prompt (the report is still printed) so
remove is usable from a script; a non-interactive shell without ``--yes``
declines safely rather than deleting. See *Preview a removal with --dry-run* to
inspect the blast radius first.

Two guards keep the graph consistent. Selecting a **callee whose caller is kept**
(an artifact on its own, a run whose job stays) is refused with a hint to remove
the caller instead or pass ``--from-root`` (see *Erase a whole lineage with
--from-root*). And a **job that has not finished** (``submitted`` / ``running`` /
``prepared``) in the erase set is a hard refusal --- stop it first with ``job
cancel``.
