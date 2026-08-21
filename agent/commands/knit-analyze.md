---
description: Answer a question about a Knit experiment's recorded runs and provenance. Read-only.
argument-hint: "<question about the results>"
---

Answer a question about the experiment's recorded runs and provenance graph.

Load the **`analyzing-results`** skill and follow it. That skill owns the
know-how; this command only frames the task.

Question: **$ARGUMENTS** (if empty, ask what the user wants to know about the
results).

How to answer:

- Load **`using-knit`** if it is not already in context.
- The posture is **Autonomous, read-only**: read and reason freely; ask only when
  the question itself is ambiguous (which metric counts as "best", which run).
- **Ask the experiment in plain English** with `knit ai query "<question>"` (one
  read-only query, run for you) and `knit ai ask "<question>"` (prose). Do **not**
  hand-write SQL/Cypher; fall back to `knit query sql` / `knit query graph` only
  when no AI endpoint is configured.

Lead with the answer, then back it with the run ids and the query you asked so the
user can re-check it. This command never mutates or re-runs the experiment.
