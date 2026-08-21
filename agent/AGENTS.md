# Working in this project with an AI agent

This project uses **Knit**, a Bash framework for reproducible and portable HPC
experiments. Its `experiment.sh` sources `knit.sh` and registers the experiment's
commands (jobs, apps, setups, plain commands); Knit gives them a CLI, typed
parameters, dependency setup, batch-job submission, and a provenance database
that records every run.

To drive this project:

- **Start from the `using-knit` skill.** It teaches the mental model, the
  read-only vs mutating split, the `prepare` / `submit` safety split, and the two
  autonomy postures every other knit skill assumes.
- **Discover the live command surface — do not assume it.** Each experiment
  exposes its own commands. Read them with `./experiment.sh describe`
  (`--format json` for machine-readable output) and `./experiment.sh <command>
  --help`. Read the experiment's runs and provenance with `knit ai query` /
  `knit ai ask`, or `knit query` when no AI endpoint is configured.
- **Prepare before you spend compute.** `prepare` records a reviewable queue and
  contacts no scheduler; `submit` is the separate step that runs jobs.

Knit ships more skills for specific tasks — writing a machine profile, authoring
an experiment, planning a sweep, driving a submission loop, analyzing results.
The harness loads each when its description matches the task. Install or refresh
them with `knit skills install`.
