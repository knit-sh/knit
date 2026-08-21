---
description: Release a prepared queue of Knit jobs and drive it to completion. Spends compute.
argument-hint: "[--group <name>] [--type <job>]"
---

Drain a prepared queue: release jobs with `submit next` (oldest first), decide
retry vs skip on failure, keep the batch moving, and report at the end.

Load the **`driving-a-submission-loop`** skill and follow it. That skill owns the
know-how; this command only frames the task.

Scope: **$ARGUMENTS** (a `--group` and/or `--type` to restrict the drain; if
empty, ask which group/batch to release, or confirm draining everything prepared).

Before releasing:

- Load **`using-knit`** if it is not already in context.
- The posture is **Autonomous**: your bound is the harness permission to run
  `knit submit` — Knit imposes no in-skill cap. Make your own retry-vs-skip and
  ordering decisions, run unattended, and report at the end what you released,
  what completed, and every deviation (a retry, a skip, a back-off, an early stop)
  with its reason.

This command **spends compute** — it is the deliberate counterpart to
`/knit-sweep`, which only prepares. Stop on repeated identical failures rather
than burning an allocation.
