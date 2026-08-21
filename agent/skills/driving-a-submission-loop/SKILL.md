---
name: driving-a-submission-loop
description: Use when releasing a prepared queue of jobs and driving it to
  completion unattended — draining with `submit next` (oldest first, scoped by
  `--type` / `--group`), deciding retry vs skip on failure, keeping jobs in
  flight, and reporting at the end. Triggers on "run the sweep", "release the
  queue", "keep N jobs in flight". This is the long-running autonomous driver.
  Assumes `using-knit` and a queue built by `planning-a-sweep`.
---

# Driving a submission loop

A prepared queue (from `planning-a-sweep` or hand-written `prepare`) is a set of
`prepared` job rows that have **not** touched the scheduler. This skill releases
them and drives the batch to completion: it spends compute. It is built to run
while the user is away.

Load `using-knit` first. This skill builds on the prepare / submit split and the
autonomous posture.

## Posture: Autonomous (report at the end)

The user has stepped away on purpose. **Your bound is the permission the user
gave their harness to run `knit submit` — Knit imposes no in-skill cap.** Drive
the queue unattended: make your own retry-vs-skip and ordering decisions, and do
**not** page the user per job.

At the end — or when you hit a stop condition you judge sensible — report what
you released, what completed, and, most important, **every deviation you had to
work around or bypass**: a job you retried, one you skipped, a queue-full
back-off, a stop you called early. Give the reason for each.

## The release primitives

- `knit submit next [--type <job>] [--group <name>] [--wait]` — release the
  **oldest** prepared job in line (prepare order). It prints the released UUID,
  and returns **non-zero when no prepared job matches** — that is the natural
  loop terminator. `--type` restricts to one job name, `--group` to one group;
  scope the loop to the batch you are draining.
- `knit submit prepared --id <uuid> [--wait]` — release one **chosen** prepared
  job by id, when you need a specific one out of order.
- `--wait` blocks until the released job completes and returns its exit code — a
  simple serial drain. Without `--wait`, the job runs in the background and you
  poll its state yourself (see below), which is how you keep several in flight.

## Drive the queue

Pick a strategy for how many jobs run at once:

- **Serial (simplest).** Loop `submit next --group <g> --wait` until it returns
  non-zero. Each job runs to completion before the next is released; the exit
  code tells you pass or fail immediately.
- **Keep N in flight.** Release without `--wait` up to your concurrency target,
  then poll `knit job list --status running` (and `--status prepared`) to decide
  when to release the next. Stop releasing when `submit next` returns non-zero
  (queue drained), and keep polling until nothing is `running`.

Scope every `submit next` to the batch (`--group`, and `--type` if the plan
mixed job kinds) so you never release a job that belongs to a different study.

## Watch state and results

Prefer asking the script over hand-writing queries:

- `knit ai query "<question>"` — "how many jobs are still running in group
  pi-sweep?", "which jobs were killed?". The in-knit model writes the read-only
  query; you read the table. Fall back to `knit query sql` / `knit query graph`
  only when no AI endpoint is configured.
- `knit job list --status <state>` (the lifecycle states are `prepared`,
  `submitted`, `running`, `completed`, `killed`; add `--json`) — a direct
  filtered listing.
- `knit job status --id <uuid>` — one job's lifecycle state.
- `knit job show stdout --id <uuid>` / `knit job show stderr --id <uuid>` — a
  job's output, to judge whether a completed job actually succeeded.

**How failure shows up.** Knit has no `failed` state: a job that runs to the end
is recorded `completed` whatever its exit code, and only a cancelled or
walltime-killed job becomes `killed`. So detect a bad run by its **exit code**,
not a state filter — `submit next --wait` (and `submit prepared --wait`) returns
the job's exit code — and confirm the cause from its stdout/stderr.

## Decide retry vs skip vs stop

On a failed job, judge the cause from its stdout/stderr and act:

- **Transient** (a node fault, a queue-full or scheduler back-off, a timeout you
  can extend) — retry. `knit job resubmit --id <uuid>` re-runs it with its
  recorded parameters under a fresh UUID. Back off before re-releasing when the
  scheduler is full rather than hammering it.
- **Deterministic** (a bad parameter, a missing input, a build error) — skip that
  job, record why, and move on; retrying it will only waste the same allocation.
- **Repeated identical failures** — **stop.** When several jobs fail the same way
  (the same error, in a row), that is a batch-wide problem, not bad luck.
  Halting to report it is your own judgment, not an imposed cap — continuing
  would burn the allocation for nothing.

Keep a running tally as you go so the final report is accurate.

## Report at the end

When the queue is drained (or you stopped early), report:

- **released / completed / failed** counts, by group;
- **every deviation**: each job retried (and why), each skipped (and why), any
  back-off taken, and the stop condition if you halted early;
- where to look next — the failing jobs' ids and `job show stdout` for the user
  to inspect.

## Safety

- Releasing spends compute. The real control is the harness permission the user
  granted for `knit submit` — respect it; do not seek to widen it.
- The `prepare` → `submit` split already let a human review the whole plan; do
  not re-prepare or alter the plan here — drive what was prepared.
- `job cancel` / `job resubmit` change state — use them deliberately and record
  the reason in your report.
- No secrets: reference environment-variable *names* only, never their values.
