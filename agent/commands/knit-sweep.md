---
description: Build a Knit prepare-from plan for a parameter sweep. Stops at a prepared queue; submits nothing.
argument-hint: "<study to sweep>"
---

Turn a parameter study into a reviewable batch of prepared jobs — a `prepare
from` JSON plan (a matrix with product / exclude / include), grouped so it can be
drained later.

Load the **`planning-a-sweep`** skill and follow it. That skill owns the
know-how; this command only frames the task.

Study: **$ARGUMENTS** (if empty, ask which job to sweep and over what axes).

Before recording anything:

- Load **`using-knit`** if it is not already in context.
- The posture is **Ask-first**: confirm the axes and their ranges, the per-point
  nodes/walltime/setup, the exclude/include list, and the group name. Read the
  target job's real parameters with `knit describe --format json` so the plan's
  `args` are valid.

This command **stops at a prepared queue** and submits nothing. Show the batch
for review (`knit job list --status prepared`). Releasing it is the separate,
compute-spending step — run `/knit-run`.
