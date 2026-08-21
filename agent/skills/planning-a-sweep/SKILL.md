---
name: planning-a-sweep
description: Use when turning a parameter study into a reviewable batch of jobs —
  "vary n over 1,2,4,…,64 and seed over 3 values, 2 nodes each" becomes a
  `prepare from` JSON plan (a matrix with product / exclude / include), grouped so
  it can be tracked and drained later. Ends at a queue of prepared jobs; submits
  nothing. Triggers on "plan a sweep", "prepare a batch of runs". Assumes
  `using-knit`.
---

# Planning a sweep

A sweep is a batch of jobs that vary over a few axes. Knit builds one with a
**plan**: a JSON document fed to `prepare from`, which records one `prepared` job
row per combination and **contacts no scheduler**. Planning and spending are
separate steps — this skill ends at a reviewable queue; `driving-a-submission-loop`
drains it later.

Load `using-knit` first. This skill builds on the prepare / submit split.

## Posture: Ask-first

The plan's shape is the user's decision, and a wrong axis multiplies into a whole
batch of wasted allocations. Before recording any rows, confirm:

- the **axes** — which parameters vary, and over what **ranges** or value lists;
- the **per-point resources** — nodes, walltime, and the setup each job needs;
- the **exclusions and additions** — combinations to drop (`exclude`) and one-off
  points to add (`include`);
- the **group name** — so the whole batch can be tracked and drained together;
- the **target job** — it must be a registered job (see below).

When any of these is unclear, ask rather than guess.

## Step 1 — read the target job's real parameters

A plan's `args` must match the job's declared parameters, so read them first
rather than assuming names:

- `knit describe --format json` — every command, its kind, and its typed
  parameters. Confirm the target is a **job** and read its parameter names,
  types, and defaults.
- `knit <job> --help` — the same detail for one job.
- The machine's node and walltime limits come from the profile
  (`knit profile show --profile <name>`); keep every point within them.

## Step 2 — write the plan

A plan is a JSON object with three top-level keys:

- `group` (optional string) — a default group applied to every prepared job (a
  per-entry `group`, or a `--group` on the command line, overrides it).
- `defaults` (optional object) — a field map merged **under** every entry, so an
  explicit field on the entry wins. Applies to concrete entries and to every
  matrix combination.
- `jobs` (required array) — the entries. Each element is **either** a concrete
  entry **or** a `matrix` block.

**Entry fields** (in a concrete entry, and in each matrix combination):

- `job` (required string) — the registered job name (the token after `--`).
- `args` (optional) — the job's own arguments. An **object** `{"n": 5}` becomes
  `--n 5` (boolean `true` is a bare flag, `false` is omitted); an **array**
  `["--n", "5"]` is passed through verbatim.
- `extra` (optional array) — raw tokens appended after `args`.
- **any other key** — a submission option (`nodes`, `walltime`, `setup`,
  `group`, …), exactly as on the `prepare` command line. An unknown key is a
  fatal plan error naming the key, so a typo is never silently dropped.

**Matrix block.** A `{ "matrix": {…} }` element expands to one job per
combination:

- `axes` — a map from field name to a list of values; the block expands to the
  cartesian product (first axis varies slowest).
- `exclude` — a list of field maps; drop every combination matching **all**
  fields of any exclude entry.
- `include` — a list of field maps; append each as a standalone combination,
  merged over the block's fixed fields (after exclude).
- every other key on the block (like `job`, a fixed `setup`) is carried into
  every combination.

A **bare axis key is a submission option** (so an `axes: { "nodes": [1,2] }`
axis varies the node count). To vary the job's **own** arguments, use an `args`
axis whose values are arg objects: `"args": [ {"seed": 1}, {"seed": 2} ]`.

Example — a baseline point plus a matrix over an argument and a submission
option, with one combination excluded and one extra point included:

```json
{
  "group": "pi-sweep",
  "defaults": { "setup": "build", "walltime": "00:10:00" },
  "jobs": [
    { "job": "estimate", "args": { "samples": 1000, "seed": 0 } },

    { "matrix": {
        "job": "estimate",
        "axes": {
          "args":  [ {"seed": 1}, {"seed": 2}, {"seed": 3} ],
          "nodes": [ 1, 2, 4 ]
        },
        "exclude": [ { "args": {"seed": 3}, "nodes": 4 } ],
        "include": [ { "args": {"seed": 42}, "nodes": 8 } ]
    } }
  ]
}
```

## Step 3 — prepare the queue (no scheduler contact)

Feed the plan to `prepare from` on stdin or from a file:

```sh
./experiment.sh prepare from --file plan.json
# or
./experiment.sh prepare from < plan.json
```

The whole plan is **validated before any job is prepared**, so a malformed plan
leaves nothing half-prepared. Jobs are prepared in plan order (matrix
combinations in product order, then includes) and `prepare from` prints one
prepared job UUID per line. Preparing spends no compute — it only records rows.

`--group <name>` on the command line overrides the plan's top-level `group` for
the whole batch.

## Step 4 — show the queue for review, then stop

This skill ends at a reviewable queue. Show what was prepared and hand off:

- `knit job list --status prepared` — the prepared rows (add `--json` for a
  machine-readable list, `--types <job>` or filters to scope it).
- Report the batch: how many jobs, over which axes, in which group, and any
  combinations excluded or added.

**Submit nothing.** Releasing the queue is the separate, compute-spending step
owned by `driving-a-submission-loop` (or a manual `submit next`). The plan sits
ready for a human to review every job before one runs.

## Safety

- Planning is read-only against the scheduler: `prepare from` records rows and
  contacts no batch system.
- Keep every point within the profile's node and walltime limits — a plan that
  over-requests wastes the whole batch at submit time.
- No secrets: put environment-variable *names* in the plan, never their values.
