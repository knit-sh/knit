---
name: writing-an-experiment
description: Use when authoring or scaffolding a Knit `experiment.sh` from a
  plain-English description — turning intent like "sweep a Monte-Carlo estimator
  over sample counts and seeds on 1-4 nodes, built with Spack" into registered
  commands with typed parameters, outputs, a setup, and a table. Triggers on
  "write an experiment that...", "scaffold a knit script for...". Assumes
  `using-knit`.
---

# Writing an experiment

An `experiment.sh` sources `knit.sh`, registers the experiment's commands, and
ends with `knit "$@"`. Your job is to turn the user's intent into the right
commands with the right typed parameters, outputs, setup, and recording — using
Knit's own idioms, not inventing new ones.

Load `using-knit` first. This skill builds on its mental model and the
"discover, do not assume" rule.

## Posture: Ask-first

Do not invent a study the user did not describe. Before scaffolding, clarify:

- the **intent** — what is being computed or measured, and what a run produces;
- the **parameters and their types** — which inputs vary, and their units/ranges;
- whether each command is a **plain command, a job, or an app** (see below);
- the **dependency story** — does it need a built library or a prepared
  environment (a setup), and is that Spack-backed or built from source;
- the **target machine** — if it runs on a cluster, a profile may be needed
  first (hand off to `writing-a-profile`).

When any of these is unclear, ask rather than guess.

## Discover the API and copy the idioms

Never author from memory. Read the live API and the canonical example:

- `knit describe --format json` on an existing experiment shows how its commands
  are shaped — copy that shape.
- **`examples/full.sh`** in the knit repo is the canonical showcase: it exercises
  every declaration in one place. Read the command near what you are building.
- The **stitch cookbook** (`docs/source/stitch/recipes/`) has short recipes by
  category (`commands`, `parameters`, `types`, `setup`, `jobs`, `apps`,
  `recording`, `resources`, `spack`, ...). Grep it for the API you need.

## Pick the command kind

- **Plain** — `knit_register <name> <fn> "<desc>"`: an ordinary recorded command
  (a local computation, an analysis step).
- **Job** — `knit_register_job <name> <fn> "<desc>"`: submitted to a scheduler as
  a batch job (`knit submit`).
- **App** — `knit_register_app <name> <fn> "<desc>"`: an MPI-capable program
  launched with `knit run` (placement across ranks/nodes). An app's body usually
  calls the real binary as a child so it joins the MPI world.
- **Setup** — `knit_register_setup <name> <fn> "<desc>"`: prepares an environment
  or builds a dependency into `KNIT_SETUP_PREFIX` (see `writing-a-setup`).
- **Wrapper** — `knit_register_wrapper ...`: forwards its arguments verbatim to an
  external tool.

## Declare the interface (between register and `knit_done`)

Each command's parameters and behavior are declared before `knit_done`:

- `knit_with_required "name:type" "<desc>"` — a required parameter.
- `knit_with_optional "name:type" "<default>" "<desc>"` — an optional one. The
  default may be `ENV[VAR]`, which resolves to the `VAR` environment variable at
  call time (handy for inheriting a setup's exported values).
- `knit_with_flag "name" "<desc>"` — a boolean flag.
- `knit_with_extra "<desc>"` — opaque `--` passthrough arguments.
- `knit_with_output "name:type" "<default>" "<desc>"` — a recorded result the
  body emits with `knit_output "name" "<value>"`.
- `knit_with_table` — record every run as a row in the command's DB table (needed
  for history, analysis, and provenance edges).
- `knit_with_setup "<type>"` — require a setup of that type before running.
- `knit_with_resource "name:<restype>" "<desc>"` — require a fetched resource.
- `knit_with_spack_specs` / `knit_with_spack_env` — a setup's Spack environment.

**Types.** Built in: `integer`, `real`, `boolean`, `string` (aliases: `int`,
`double`/`float`, `bool`). Define an enum with `knit_define_enum "<name>"
"<value>"...` and use it as a type (for example `format:numfmt`). Types drive
validation, `--help`, and the SQLite column type.

## Write the body

Inside the function, read parameters and emit outputs:

```bash
knit_register "estimate" estimate "Estimate pi locally with Monte-Carlo."
knit_with_required "samples:integer"        "Number of random samples."
knit_with_optional "seed:integer" "42"      "PRNG seed (fixed for reproducibility)."
knit_with_flag     "verbose"                "Print progress on stderr."
knit_with_table                             # record every run as a DB row
knit_with_output   "pi:real" "0"            "The estimated value of pi."
estimate() {
    local samples seed
    samples=$(knit_get_parameter "samples" "$@")
    seed=$(knit_get_parameter "seed" "$@")
    # ... compute ...
    knit_output "pi" "${result}"
}
knit_done
```

Follow the conventions of the surrounding code and of `examples/full.sh`: hyphens
in parameter names, one declaration per line, `knit_get_parameter` to read,
`knit_output` to record. End the whole script with `knit "$@"`.

## Verify — but do not run compute unprompted

Authoring is pure. After writing, verify the surface with discovery, not by
spending compute:

- `./experiment.sh describe` (or `<command> --help`) — confirm every command,
  parameter, type, default, and output reads as intended.
- Fix declarations until `describe` matches the user's intent.

**Running what you wrote is a separate, confirmed step.** A local plain command
is cheap to try; a job or app spends real compute and belongs to the driving
skills (`planning-a-sweep`, `driving-a-submission-loop`) under the user's
go-ahead. If the experiment needs a dependency, hand off to `writing-a-setup`;
if it targets a cluster with no profile yet, hand off to `writing-a-profile`.

## Safety

- Pure authoring is free; running a job or app is gated and confirmed.
- Do not overwrite an existing `experiment.sh` without first reading it and
  confirming — match its conventions instead of replacing them.
- No secrets: reference environment-variable *names*, never their values; never
  write a key or token into the script.
