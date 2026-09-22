..
   title: Prepare many jobs from a plan
   categories: jobs
   order: 70
   description: Prepare a whole batch of jobs from a JSON plan, including a GitHub-Actions-style matrix.
   apis: prepare:from

To prepare a whole batch at once, describe it in a JSON plan and feed it to
``prepare from`` --- from a file with ``--file``, or on stdin when ``--file`` is
omitted. Each entry is prepared as if you had run ``prepare -- <job> …`` by hand:

.. knit-code:: /_code/prepare.sh
   :language: json
   :start-after: <<'JSON'
   :end-before: JSON

**Plan schema.** A plan is a JSON object with three top-level keys:

- ``group`` (optional string) --- a default group applied to every prepared job
  (a per-entry ``group``, or a ``--group`` on the command line, overrides it).
- ``defaults`` (optional object) --- a field map merged **under** every entry, so
  an explicit field on the entry wins. Applies to concrete entries and to every
  matrix combination. The ``args`` object is deep-merged: an entry (or a matrix
  combination) overrides only the arguments it names and keeps the rest of
  ``defaults.args``, so you can sweep one argument in a matrix while sharing the
  others through ``defaults.args``. (An ``args`` given as a raw-token **array**
  takes full control and does not merge with ``defaults.args``.)
- ``jobs`` (required array) --- the entries to prepare. Each element is **either**
  a concrete entry **or** a ``matrix`` block.

**Entry fields.** Within a concrete entry (and within each matrix combination):

- ``job`` (required string) --- the registered job name (the token after ``--``).
- ``args`` (optional) --- the job's own arguments. An **object** ``{"n": 5}``
  becomes ``--n 5`` (a boolean ``true`` is a bare flag, ``false`` is omitted); an
  **array** ``["--n", "5"]`` is passed through as raw tokens verbatim.
- ``extra`` (optional array) --- raw tokens appended after ``args``.
- **any other key** --- a submission option (``nodes``, ``walltime``, ``setup``,
  ``group``, ...), exactly as on the ``prepare`` command line. An unknown key is a
  fatal plan error naming the key, so a typo is never silently dropped.

**Matrix expansion.** A ``matrix`` block expands to one prepared job per
combination: the cartesian product of its ``axes``, minus every ``exclude``
combination, plus each ``include`` entry appended as a standalone combination.
The block's fixed fields (like ``job``) are carried into every combination.
Because a bare axis key is a submission option, an axis varies a submission field
(like ``nodes``) directly; to vary the job's **own** arguments, use an ``args``
axis (see *Varying job arguments* below). The plan above expands to five prepared
jobs: the ``baseline`` entry, three surviving product combinations
(``a``/1, ``a``/2, ``b``/1 --- ``b``/2 is excluded), and the ``c``/4 include.

Feed the plan on stdin (a here-doc, here-string, or pipe) or from a file:

.. code-block:: console

   $ ./exp.sh prepare from --file plan.json
   $ ./exp.sh prepare from < plan.json

The whole plan is validated before any job is prepared, so a malformed plan leaves
nothing half-prepared. Jobs are prepared in plan order (matrix combinations in
product order, then includes), so ``submit next`` later releases them in that
order --- see *Release prepared jobs*.

Varying job arguments
^^^^^^^^^^^^^^^^^^^^^^

A submission field (``nodes``, ``queue``, ...) is a bare axis key, but a job's own
arguments live under ``args``. The ``args`` axis takes **either** shape:

- an **object** of sub-axes --- ``"args": { "n": [1,2], "label": ["a","b"] }`` ---
  where each key is an independent argument axis, so the matrix is their full
  product (times any submission axes);
- an **array** of complete arg objects --- ``"args": [ {"n":1}, {"n":8} ]`` --- a
  single axis of pre-built tuples, for arguments that must vary **together**.

An ``exclude`` matches a submission field by value, but matches ``args`` as a
**subset**: it need only name the sub-keys you want to pin, so it can drop
combinations by a single argument. This plan takes the product of ``nodes``,
``n``, and ``label`` (``2 x 2 x 2 = 8``), then drops every ``label`` = ``b``
combination (an ``args`` subset), leaving four prepared jobs:

.. knit-code:: /_code/prepare.sh
   :language: json
   :start-after: <<'ARGSPLAN'
   :end-before: ARGSPLAN
