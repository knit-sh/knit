---
description: Scaffold or extend a Knit experiment.sh from a plain-English intent.
argument-hint: "<what the experiment should do>"
---

Turn an intent into a Knit `experiment.sh` — registered commands with typed
parameters, outputs, a setup, and a table.

Load the **`writing-an-experiment`** skill and follow it. That skill owns the
know-how; this command only frames the task.

Intent: **$ARGUMENTS** (if empty, ask what the experiment should compute or
measure).

Before writing anything:

- Load **`using-knit`** if it is not already in context.
- The posture is **Ask-first**: clarify the intent, which parameters vary and
  their types, whether each command is a plain command / job / app, the
  dependency story (a setup? Spack or built from source?), and the target
  machine. Do not invent a study the user did not describe.
- Discover the real API before authoring: `knit describe --format json` on any
  existing experiment, `examples/full.sh`, and the stitch cookbook.

Authoring is free; **running** what you write is a separate, confirmed step —
hand off to `planning-a-sweep` / `driving-a-submission-loop` to spend compute, to
`writing-a-setup` for a dependency, or to `writing-a-profile` for a new cluster.
Do not overwrite an existing `experiment.sh` without reading it and confirming.
