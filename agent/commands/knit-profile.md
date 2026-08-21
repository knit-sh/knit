---
description: Write or fix a Knit machine profile for an HPC cluster, then validate it.
argument-hint: "[machine name]"
---

Onboard Knit to a machine by writing (or fixing) its profile.

Load the **`writing-a-profile`** skill and follow it. That skill owns the
know-how; this command only frames the task.

Target machine: **$ARGUMENTS** (if empty, ask which machine, or infer it from the
current host).

Before writing anything:

- Load **`using-knit`** if it is not already in context.
- The posture is **Ask-first**: ask the user for the account/allocation, the queue
  names and their node/walltime limits, the modules a build needs, and any vendor
  library that must not be rebuilt. Do not guess these.
- Start from a shipped profile as a template (`knit profile list`,
  `knit profile show --profile <name>`), not a blank page.

A profile is done only when the bundled validation harness passes end to end
(build → 2-node submit → launch → placement). The single validation job spends a
real allocation — confirm the go-ahead, the account, and the queue with the user
before submitting it.
