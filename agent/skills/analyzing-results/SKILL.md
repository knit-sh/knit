---
name: analyzing-results
description: Use when answering questions about a bootstrapped experiment's
  recorded runs and provenance — "which runs were slowest?", "did the seed sweep
  converge?", "what produced this output?". Ask the experiment in plain English
  with `ai query` / `ai ask`; do not hand-write SQL or Cypher against the schema.
  Triggers on "analyze the results", "summarize the runs", "what happened in this
  study". Read-only. Assumes `using-knit`.
---

# Analyzing results

Every mutating action in a knit experiment is recorded — a typed row per run and
a provenance graph of what produced what. This skill answers questions against
that record. It is **read-only**: it reads and reasons, it does not run compute
or change state.

Load `using-knit` first. This skill builds on its "ask the script, do not craft
the query yourself" rule.

## Posture: Autonomous (read-only)

The record is fixed and reading it is free, so gather and reason on your own —
run as many read-only queries as the question needs, then summarize. **Ask the
user only when the question itself is ambiguous** (which metric counts as "best",
which run out of several the user means). Do not ask permission to read.

## The one rule: ask in plain English, do not write the query

Knit ships a small in-knit model that already knows the database schema, the
column names, the command-name aliases, and the provenance edge model. Use it —
reaching for the schema and writing SQL or Cypher by hand pollutes your context
for no gain, and the model does it better and cheaper.

- `knit ai query "<question>"` — the model writes **one read-only** SQL or Cypher
  query, knit runs it, and you get the result table. For example:
  `knit ai query "the 5 slowest runs"`, `knit ai query "which jobs were killed?"`.
  Useful flags: `--format <box|csv|list|json|markdown|…>` shapes the output;
  `--lang <auto|sql|cypher>` pins the language (default `auto`); `--query-only`
  prints the query it *would* run without running it (good for showing your work);
  `--verbose` streams each generated query and any backend error to stderr.
- `knit ai ask "<question>"` — a **prose** answer about the experiment, when you
  want an explanation rather than a table.

Run several `ai query` calls to build up an answer — counts, then the outliers,
then the provenance of a specific run — and synthesize. That is the intended
workflow.

## Fallback: query by hand only when there is no AI endpoint

`ai query` / `ai ask` need an AI endpoint configured at bootstrap. If none is
(the call reports no endpoint), **then and only then** query the database
directly. First learn the shape, then read:

- `knit query catalog` — list every table and its columns (add a `TABLE` or
  `TABLE.COLUMN` ref to show or validate one). Read this before writing a query
  so you use real column names.
- `knit query sql "<SQL>"` — run read-only SQL against the run/job tables.
- `knit query graph "<Cypher>"` — run a Cypher query against the provenance graph
  (which run produced what, which job a run belongs to). `--explain` / `--ast`
  show the plan without touching data.

Each accepts `--format` and `--header` / `--separator` to shape output. Treat
this as the fallback path — prefer `ai query` whenever the endpoint exists.

## What the record holds

- **Per-command tables** — one row per recorded run of a command that declared a
  table, with its typed parameters and outputs. This is where results and timings
  live.
- **The `jobs` table** — submitted jobs with their lifecycle `state`
  (`prepared` / `submitted` / `running` / `completed` / `killed`), setup, group,
  and allocated hostnames.
- **The provenance graph** — typed edges linking a submission to the run it
  produced, a run to the per-app rows it recorded, and a command to the setup or
  resource it used. This is what lets you answer "what produced this?".

Ask the model about any of these in plain English; it maps the question onto the
right table or edge for you.

## Answer, then show your work

- Lead with the answer to the user's actual question — the number, the ranking,
  the yes/no — not a raw table dump.
- Back it with the evidence: the run ids, the values, the query you asked (use
  `--query-only` or quote the `ai query` you ran) so the user can re-check it.
- Note any gap honestly: a question the record cannot answer (a metric never
  recorded), or a run still `running` so its outputs are not final yet.

## Safety

- This skill is read-only: `ai query` / `ai ask` / `query` do not mutate. Never
  reach for a mutating command to answer an analysis question.
- If a question needs a value that was never recorded, say so — do not re-run the
  experiment to produce it (that is a driving task, gated and confirmed).
- No secrets: reference environment-variable *names*, never their values, in
  anything you write.
