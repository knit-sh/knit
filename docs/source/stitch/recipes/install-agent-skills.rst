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
copies the skills and commands into the harness layout. The skills are not
embedded in ``knit.sh``, so they always track the published repo rather than the
installed script.

**Target layout.** The default target is the cross-harness ``.agents/``
directory; ``--harness claude`` installs into ``.claude/`` instead. Only the
destination changes --- the content is identical.

.. code-block:: console

   $ ./exp.sh skills install                 # -> .agents/skills, .agents/commands
   $ ./exp.sh skills install --harness claude # -> .claude/skills, .claude/commands

The copy **merges** into any skills/commands already there, so skills from other
sources are preserved and re-running the command is idempotent. Install also drops
an ``AGENTS.md`` pointer at the project root (so an agent orients itself before
any skill is loaded), but never overwrites an ``AGENTS.md`` the project already
has.

**Pinning a version.** ``--ref`` installs the skills from a specific branch, tag,
or commit of ``knit-sh/knit`` instead of the default branch:

.. code-block:: console

   $ ./exp.sh skills install --ref v1.4.0

Because install writes a *tree* of files rather than a single stream, there is no
``--print`` mode.
