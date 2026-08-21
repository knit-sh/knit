# Profile validation harness

A small, self-contained knit experiment that proves a machine profile actually
works end to end. It is the smoke test the `writing-a-profile` skill runs before
it calls a profile "done": a profile that only parses is not enough — the build
toolchain, the scheduler, and the launcher all have to be right.

It mirrors knit's own `09_run_app` integration test, reduced to one bundled
experiment, so the agent runs a known-good test instead of writing one each time.

## Files

- `mpi_hello.c` — a tiny MPI program. Each rank prints one line
  `RANK=<r> SIZE=<n> HOST=<hostname>`.
- `experiment.sh` — the knit experiment: a `build` setup (compiles the program
  with the profile's `mpicc`), a `hello` app (one MPI rank of the program), and a
  `validate` job (launches the app across the allocation with `knit run`).
- `check.sh` — parses the job's captured stdout and asserts rank placement.

## What it proves

1. **Build toolchain.** The `build` setup compiles `mpi_hello.c` with `mpicc`,
   which the profile's modules must put on `PATH`. A wrong toolchain fails here.
2. **Scheduler.** `submit --nodes 2` reaches the batch system and is granted a
   two-node allocation.
3. **Launcher.** The `validate` job body runs `knit run --procs 4
   --procs-per-node 2 -- hello`, so the launcher spreads four ranks, two per
   node, across both nodes.
4. **Placement.** `check.sh` confirms the ranks are distinct and complete
   (0..N-1), agree on the world size, and are spread across both nodes — not all
   crowded onto one.

## Running it

`knit.sh` must sit beside `experiment.sh` (the script uses a bare `source
knit.sh`), so copy your project's `knit.sh` into this directory first.

```sh
cp /path/to/your/project/knit.sh .
./experiment.sh bootstrap --project profile-validation
./experiment.sh setup --name build -- build
uuid=$(./experiment.sh submit --setup build --nodes 2 --wait \
         -- validate --procs 4 --procs-per-node 2)
bash check.sh "${uuid}" 4 2
```

`check.sh` exits non-zero if any check fails and prints a `FAIL` line naming the
failing property, so the failing step and its evidence are explicit. The 2-node
job is a real (if tiny) allocation — the skill confirms it with the user before
this step.

To exercise a specific launcher instead of the auto-detected MPI-native one, add
`--launcher <name>` (for example `slurm`, `pbs`) to the `validate` arguments.
