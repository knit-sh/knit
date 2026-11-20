..
   title: Replay a session from its history
   categories: recording
   order: 60
   description: knit history show prints the top-level commands you ran, in time order, as plain lines, a bash replay script, or json.
   apis: history:show

Every top-level command you run against an experiment is recorded, in time
order, as a replayable **history** --- just the commands *you* invoked, not the
work they spun off (a submitted job's compute-side app, a drain's internal
``submit next``, a sweep's fan-out are all left out). ``knit history show``
prints it:

.. code-block:: console

   $ ./exp.sh history show
   setup --name env -- mcenv
   submit --nodes 4 -- montecarlo --samples 100000
   analyze

By default only successful commands appear; pass ``--status all`` to include
failures (or ``--status failure`` for just those). Narrow the list with
``--command`` (comma-separated, colon notation; a ``:*`` suffix also matches
subcommands), a ``--since``/``--until`` time window (a UUID or an ISO-8601
timestamp), ``--first``/``--last N``, or ``--id``.

**Replay the session.** ``--format bash`` turns the history into an *indicative*
replay script --- a shebang, a warning comment block, then one ``./<script>
...`` line per command. It is a guide, not a guaranteed-runnable script: the
history records each command you typed, but not the shell steps you took between
them (for example, a job id you kept from a ``submit`` in a variable and reused
in a later command). Examine and edit the script before you run it:

.. code-block:: console

   $ ./exp.sh history show --format bash > replay.sh
   $ less replay.sh        # review it first --- note the warning in the header
   $ bash replay.sh

The command lines record the arguments exactly as you typed them. Add ``--resolved`` to
pin instead the values each command actually ran with (optional defaults filled,
flags normalized, ``ENV[...]`` defaults resolved), so a replay reproduces the
original behavior even if a default later changes. Knit does not resolve the
dispatched target after ``--`` (a job or setup's own defaults): what each
dispatched command actually ran with is recorded in its own table and the
provenance graph.

**Structured output.** ``--format json`` emits one ``{name, args, extra}`` object
per command --- ``args`` is the map of options before ``--`` (a flag renders as a
boolean), ``extra`` the tokens after it (the dispatched target and its
arguments):

.. code-block:: console

   $ ./exp.sh history show --format json
   [{"name":"analyze","args":{"digits":"5"},"extra":[]}]

Annotate any format with ``--annotate`` to prefix each entry with its id, time,
and exit status, and write to a file instead of standard output with
``--output``.
