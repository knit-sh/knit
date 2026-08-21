---
name: using-knit
description: Load first for any task that uses Knit — the Bash framework for
  reproducible HPC experiments. Teaches the mental model, how to discover the live
  command surface with `knit describe`/`--help`/`knit query`, the read-only vs
  mutating split, the prepare/submit safety split, and the two autonomy postures.
  Every other knit skill assumes this one.
---

# Using Knit

Knit is a Bash framework for reproducible and portable HPC experiments. A user
writes an `experiment.sh` that sources `knit.sh` and registers commands. Knit gives
that script a CLI, typed parameters, environment and dependency setup, job
submission to a batch scheduler, and a provenance database that records every run.

This skill is the orientation. It teaches the durable model and, most important,
**how to discover the rest at runtime**. Load it before any other knit skill.

## The one rule: discover, do not assume

Knit tells you exactly what an experiment exposes. Always read the live surface;
never hardcode a command or a parameter from memory.

- `knit describe` — the whole command tree with parameters, types, defaults, and
  help. Add `--format json` (or `yaml` / `markdown`) for machine-readable output.
  Use this first to learn what the current experiment offers.
- `knit <command> --help` — the same detail for one command, at the point of use.
- `knit query ...` — read the run/job database and the provenance graph (see
  below).

Experiments differ. The command list is theirs, not yours — read it, do not guess
it. `./experiment.sh describe --format json` is the correct opening move on an
unfamiliar experiment.

## Mental model

- **`experiment.sh`** sources `knit.sh` and registers the experiment's commands.
  Run it as `./experiment.sh <command> [options]`.
- **`.knit/`** is the runtime directory (created by `bootstrap`): it holds the
  SQLite database, and provisioned tools. It is not committed.
- Commands come in a few **kinds**:
  - **job** — submitted to a scheduler (Slurm / PBS / Flux / …) as a batch job.
  - **app** — an MPI-capable program launched with `knit run` (placement over
    ranks and nodes).
  - **setup** — prepares an environment or builds a dependency into
    `KNIT_SETUP_PREFIX` (often Spack-backed).
  - **plain** — an ordinary recorded command.
  - **wrapper** — forwards its arguments to an external tool (for example
    `knit spack ...`).
- Every mutating action is **recorded** in the database with typed provenance
  edges, so the work is auditable and a reproducer can retrace it.

`knit describe` marks each command's kind and parameters — read it rather than
inferring a command's kind from its name.

## Read-only vs mutating

Split every action into one of two classes. This split is the basis of safe
driving.

- **Read-only — call freely.** `describe`, `profile list` / `profile show`,
  `job list` / `job show` / `job status`, `job show stdout` / `job show stderr`,
  `query sql` / `query graph` / `query catalog`, `ai ask` / `ai query`,
  `metadata show` / `metadata load`.
- **Mutating — treat with care.** `bootstrap`, `prepare` / `prepare from`,
  `submit` / `submit next` / `submit prepared`, `run`, `setup`, `job cancel` /
  `job resubmit`, `metadata store`, `fetch`. These write files, spend compute, or
  change state.

When unsure whether a command mutates, check its help before running it, or ask.

### Usable before bootstrap

A fresh checkout has no `.knit/` yet. A few commands still work: `bootstrap`,
`describe`, and `profile`. That is exactly what you need when you onboard a new
machine — you can inspect and profile before anything is provisioned.

## The prepare / submit split (the key safety primitive)

Planning and spending are separate steps. Use them.

1. **`prepare`** (and `prepare from` for a matrix plan) records job rows in the
   database and **contacts no scheduler**. Nothing runs. You get a reviewable
   queue of `prepared` jobs.
2. **`submit next`** releases the oldest prepared job (time-ordered ids), and
   `submit prepared --id <id>` releases a chosen one. This is where compute is
   spent.

Build the whole plan with `prepare`, show it for review, then drain it with
`submit`. A human can inspect every job before a single one runs. This is the most
important primitive for any agent that drives compute.

## Reading history and results

**Ask the script in plain English. Do not craft the query yourself.** Knit ships a
small in-knit model that already knows the database schema. Use it:

- `knit ai query "<question>"` — the model writes one read-only SQL or Cypher
  query, knit runs it, and you get the result table. For example: "which jobs
  failed?", "the 5 slowest runs".
- `knit ai ask "<question>"` — a prose answer about the experiment.

Reaching for the schema and writing SQL by hand pollutes your context for no gain —
the script does it better and cheaper. Ask it directly.

**Fallback only when there is no AI endpoint.** If the experiment was not
bootstrapped with an AI endpoint (`ai` is not initialized), `ai query` / `ai ask`
are unavailable. Then, and only then, query the database yourself:

- `knit query sql "<SQL>"` — the run/job tables.
- `knit query graph "<Cypher>"` — the provenance graph (which run produced what,
  which job a run belongs to).

If an `ai` call reports that no endpoint is configured, switch to `query` for that
task rather than treating it as a hard failure.

## Autonomy posture

Every knit skill declares how it treats an **absent user**. Know which posture you
are in before you act.

- **Ask-first (interactive).** For authoring and onboarding — writing a profile, an
  experiment, or a setup. A wrong guess there is costly and hard to detect. **Ask
  the user rather than guess** a missing fact: a module name, an allocation or
  account to charge, a partition/queue, a node or walltime limit, a vendor library
  that must not be rebuilt, or the real intent of the study. Pausing to ask is
  better than inventing a plausible value.
- **Autonomous (report-at-end).** For long-running driving — releasing a queue,
  watching a sweep — where the user has stepped away on purpose. Your bound is the
  permission the user gave their harness (for example, allowing `knit submit`);
  Knit imposes no artificial cap. Decide the retry-vs-skip and ordering questions
  yourself, run unattended, and do not page the user per step. Stop on repeated
  identical failures rather than waste an allocation. At the end, report what you
  did and — most important — everything you had to work around or bypass, and why.

The user controls spend by granting or withholding their harness's permission to
run mutating commands — not by a limit you invent.

## Safety, always

- Read-only tools are free; mutating tools are gated by the posture above.
- Prepare before submit; the user controls spend through the permission they grant
  their harness to run mutating commands.
- Destructive actions (`job cancel`, overwriting an existing `experiment.sh`,
  profile, or a bootstrapped `.knit/`) are confirmed against what is actually there
  first.
- **No secrets.** Reference environment-variable *names*, never their values. Never
  write a key or token into a file you create.
