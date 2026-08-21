..
   title: Install the agent skills into a harness
   categories: agent
   order: 10
   description: Equip an AI harness to drive the experiment with knit skills install.
   apis: skills:install

Knit ships **agent skills and commands** --- the know-how an external AI harness
(Claude Code is the reference) needs to write a machine profile, author an
experiment, plan and run a sweep, and analyze results. Install them into the
project with ``knit skills install``:

.. code-block:: console

   $ ./exp.sh skills install

This **downloads the latest** ``agent/`` folder from the knit GitHub repository
(with ``curl`` + ``tar``, the same way ``bootstrap`` provisions its tools) and
copies the skills and commands into ``.agents/`` --- the canonical cross-harness
location. The skills are not embedded in ``knit.sh``, so they always track the
published repo rather than the installed script.

The copy **merges** into any skills/commands already there, so skills from other
sources are preserved and re-running the command is idempotent. Install also drops
an ``AGENTS.md`` pointer at the project root (so an agent orients itself before
any skill is loaded), but never overwrites an ``AGENTS.md`` the project already
has.

**Claude Code.** Claude Code looks under ``.claude/`` rather than ``.agents/``.
Add ``--claude`` to point it at the same install --- there is one real copy on
disk, not a per-harness fork:

.. code-block:: console

   $ ./exp.sh skills install --claude

This keeps ``.claude/skills`` and ``.claude/commands`` as real directories and
symlinks each knit item into them one at a time --- every skill and every command
its own symlink. So the project's own ``.claude`` skills/commands and its
``.claude/settings.json`` sit alongside the links untouched, and an item whose
name already exists is skipped with a warning rather than overwritten. Re-running
is idempotent (knit's own links are refreshed quietly).

**Pinning a version.** ``--ref`` installs the skills from a specific branch, tag,
or commit of ``knit-sh/knit`` instead of the default branch:

.. code-block:: console

   $ ./exp.sh skills install --ref v1.4.0

Because install writes a *tree* of files rather than a single stream, there is no
``--print`` mode.
