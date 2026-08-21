---
name: writing-a-profile
description: Use when onboarding Knit to a new machine — writing or fixing a
  machine profile (scheduler, launcher, modules, vendor externals, queue limits)
  for an HPC cluster. Triggers on "write a profile for <machine>", the first run
  on a new cluster, or a wrong / `<unknown>` scheduler or launcher detection. Ends
  by validating the profile with a real 2-node MPI job. Assumes `using-knit`.
---

# Writing a machine profile

A **profile** is a small JSON file that tells Knit how one machine works:
its scheduler, its MPI launcher, the modules that make a build succeed, the
vendor libraries that must **not** be rebuilt, and the queues with their node and
walltime limits. Knit can auto-detect a scheduler and launcher, but detection
cannot know your account, your queues, or which vendor MPI to adopt — the profile
pins those. `bootstrap --profile <spec>` applies it, prepopulating scheduler,
launcher, and hardware defaults.

Load `using-knit` first. This skill builds on its "discover, do not assume" rule.

## Posture: Ask-first

Machine facts are costly to guess and hard to detect wrong — a wrong account
wastes an allocation, a wrong module breaks every build, a rebuilt vendor MPI
runs but performs terribly. **Ask the user for anything you cannot read with
confidence** rather than inventing a plausible value:

- the allocation / account to charge, and the partition or queue names;
- each queue's node and walltime limits (min/max);
- which modules to load so a build finds the compiler and MPI;
- any vendor external that must be adopted, not rebuilt (for example
  `cray-mpich`, a Slingshot `libfabric`);
- cores- and GPUs-per-node when you cannot detect them.

Guessing a launcher or an account is worse than pausing to ask.

## Step 1 — discover, do not start from a blank page

Knit ships profiles for real machines; use the nearest one as a template.

- `knit profile list` (add `--hidden` to see all) — the shipped profiles.
- `knit profile show --profile <name>` — the full JSON of a profile for a similar
  machine (same scheduler family, same vendor). Copy its shape; do not invent
  keys.
- `knit bootstrap --help` — the fields a profile prepopulates and the valid
  scheduler / launcher values.

Pick the closest shipped profile (by scheduler and vendor, e.g. a Cray EX with
PBS + PALS, or a Slurm + Slingshot machine) and read it with `profile show`.

## Step 2 — gather the machine's facts

Read what the machine itself reports, and **ask the user** for the rest (see the
posture above). Useful probes, when available:

- Scheduler: `sinfo` / `squeue` (Slurm), `qstat` / `qsub --help` (PBS), `flux
  resource` (Flux). Confirm the queue names and their limits with the user.
- Launcher and MPI: `mpirun --version` / `mpicc --version`, `srun --version`.
- Modules: `module avail`, `module list`; ask which set makes a build work.
- Hardware: cores and GPUs per node (site docs or `lscpu` / `nvidia-smi` on a
  compute node); ask if unsure.

## Step 3 — write the profile JSON

Author a JSON file modeled on the template from Step 1. The schema Knit reads:

- `name`, `description` — identity strings.
- `scheduler` — `type` (`slurm` | `pbs` | `flux` | `local` | `none`), `command`,
  `default_queue`, `default_args` (a list), and `queues`, a map of queue name to
  `{ min_nodes, max_nodes, min_walltime, max_walltime, default_walltime }`.
- `launcher` — `type` (`openmpi` | `mpich` | `pals` | `flux` | `slurm` | `pbs` |
  `none`), `command`, optional `default_args`.
- `hardware` — `cores_per_node`, `gpus_per_node`.
- `modules` — the list of modules to load.
- `spack` (optional) — `packages`, where a vendor library is an **external** that
  must not be rebuilt: give it `externals` (each with `spec`, `prefix`,
  `modules`) and `buildable: false`. This is how you tell Knit to adopt
  `cray-mpich` or a site `libfabric` instead of building its own.

Write it to a local file (for example `<site>/<machine>.json`); Knit resolves a
local file path directly, which is the offline authoring story. Do **not** put any
secret, key, or token in it — reference environment-variable *names* only.

## Step 4 — validate the profile (the core of this skill)

A profile is **not done because it parses**. Validate it with a real end-to-end
run using the bundled harness in this skill's `validate/` directory, which builds
an MPI program, submits a 2-node job, launches it, and checks rank placement.
Read `validate/README.md` for the details; the sequence is:

```sh
cd validate
cp /path/to/the/project/knit.sh .          # knit.sh must sit beside experiment.sh
./experiment.sh bootstrap --project profile-validation --profile /path/to/<machine>.json
./experiment.sh setup --name build -- build
uuid=$(./experiment.sh submit --setup build --nodes 2 --wait \
         -- validate --procs 4 --procs-per-node 2)
bash check.sh "${uuid}" 4 2
```

This is the one place the profile spends compute, and a 2-node job is a real (if
tiny) allocation: **confirm the go-ahead, the account, and the queue with the
user before submitting.**

What each step proves: the `build` setup proves the profile's compiler/modules
are right; `submit --nodes 2` proves the scheduler is reached and an allocation
granted; `knit run` inside the job proves the launcher is wired; `check.sh`
proves placement — ranks distinct, complete `0..N-1`, one world size, and spread
across both nodes.

Treat the profile as done **only when `check.sh` exits cleanly** (all `PASS`). On
any `FAIL`, report the failing step and its evidence — the compiler error, the
scheduler rejection, or the placement mismatch — and fix the corresponding part
of the profile (modules for a build failure, `scheduler` for a submit failure,
`launcher` for a placement failure). Do not silently accept a profile that failed
a check.

## Safety

- Profile authoring is read-only against the cluster **except** the single
  validation job in Step 4, which is confirmed with the user first.
- Never write a secret into the profile; reference environment-variable names,
  never their values.
- If a scheduler or launcher still detects as `<unknown>` after your profile is
  applied, that is a signal the profile's `type` is wrong — fix it and re-run the
  validation rather than forcing a value.
