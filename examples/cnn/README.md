# CNN image-classifier example

This example is the companion to **Part III of the knit tutorial**. It is a
complete, runnable knit experiment built around a real machine-learning program:
the `cifar-cnn` classifier
([knit-sh/image-classifier-example](https://github.com/knit-sh/image-classifier-example)).
It trains a small, configurable convolutional network on CIFAR-10/100 and records
the validation accuracy of every run.

## Commands

A worked run across four HPC machines. The invariant parts are the same
everywhere; the per-platform differences are the setup type (accelerator) and the
scheduler flags.

### 1. Bootstrap — provision the tooling

Describe the site once here with its machine profile. This script was tested
on the following platforms.

```bash
./exp.sh bootstrap --profile <profile> --account <your-account>
```

| Platform | `--profile` | List your available account |
|---|---|---|
| Aurora | `anl/aurora/xpu` | `sbank` |
| Polaris | `anl/polaris` | `sbank` |
| Perlmutter | `nersc/perlmutter/gpu` | `iris` |
| Improv | `anl/improv` | `sbank` |

Note: on Perlmutter's GPFS filesystem, use `--db-lock mkdir` as `flock`
isn't supported from compute nodes.

### 2. Fetch — download the CIFAR-10 dataset

```bash
./exp.sh fetch --name cifar -- cifar --uncompress
```

### 3. Setup — build the `cnnenv` environment

The instance name is always `cnnenv` (so every downstream `--setup cnnenv` is
unchanged); only the setup **type** differs by accelerator:

| Platform | Accelerator | Command |
|---|---|---|
| Aurora | Intel Max GPU (XPU) | `./exp.sh setup --name cnnenv -- cnnenv-xpu` |
| Polaris | NVIDIA A100 | `./exp.sh setup --name cnnenv -- cnnenv-cuda` |
| Perlmutter | NVIDIA A100 | `./exp.sh setup --name cnnenv -- cnnenv-cuda` |
| Improv | AMD EPYC (CPU) | `./exp.sh setup --name cnnenv -- cnnenv-cpu` |

### 4. Smoke test — run a single `train` job

Before committing to a whole sweep, confirm one job runs end to end (1 epoch).

```bash
./exp.sh submit --nodes 1 --queue debug --walltime 00:30:00 --setup cnnenv \
    -- train --data cifar --dataset cifar10 --epochs 1
```

Per-platform scheduler flags (the invariant job part is unchanged):

| Platform | Scheduler flags |
|---|---|
| Polaris / Aurora | `--nodes 1 --queue debug --walltime 00:30:00` |
| Improv | `--nodes 1 --queue debug --walltime 00:30:00` |
| Perlmutter | `--nodes 1 --queue debug --walltime 00:30:00` |

> On Polaris and Aurora the default `prod` queue requires many nodes (10 and 256),
> so a single-node job must use `--queue debug`. On Perlmutter, make sure to use
> an allocation that has access to GPU nodes (usually these end in `_g`).

The `submit` command will print a UUID. Monitor the job status with:

```bash
./exp.sh job list
./exp.sh job status --id <UUID>
```

Once it completes, show its stdout and stderr:

```bash
./exp.sh job show stdout --id <UUID>
./exp.sh job show stderr --id <UUID>
```

Note: this job's output is all in stderr.

### 5. Sweep — a 6-point grid, inside one pilot allocation

Prepare one `train` job per grid point for the pilot backend (1 node per
sub-job), then submit a 2-node pilot whose daemon packs the jobs onto its nodes:

```bash
./exp.sh sweep -- prepare --group grid --setup cnnenv --backend pilot --nodes 1 \
    -- train --data cifar --dataset cifar10 \
       --num-blocks '{2,3,4}' --kernel-size '{3,5}'

./exp.sh submit --nodes 2 --queue debug --walltime 01:00:00 \
    -- sweep-pilot --group grid --max-inflight 2
```

Each `train` job launches the actual training through `knit run`, so with
`--max-inflight 2` the two concurrent jobs run on **different** allocated nodes:
the daemon assigns one node to each, and `knit run` places the training on the
node assigned to its job. This matters because a sub-job's body itself runs on the
pilot's *launch* node — only the work it launches through `knit run` reaches the
node the daemon set aside for it. A bare `cifar-cnn` call would keep both jobs on
the launch node, oversubscribing it while the second node sat idle. (Part III,
Step 6 of the tutorial covers this placement rule in full.)

#### If the pilot runs out of walltime

On a slower machine — for example the CPU-only Improv setup, where each `train`
job takes much longer than on a GPU — the grid may not finish inside the pilot's
wall-clock limit. The scheduler then kills the pilot mid-sweep. `job list` shows a
mix of states: the finished jobs are `completed`, the jobs that were running at the
kill are `killed`, any job not yet started is still `prepared`, and the pilot row
itself is `killed`. For example:

```
01a21c50-b13a-...  train        completed
01a21c50-b2e2-...  train        completed
01a21c50-b478-...  train        completed
01a21c50-b5ec-...  train        killed
01a21c50-b782-...  train        killed
01a21c50-b918-...  train        prepared
01a21c51-407a-...  sweep_pilot  killed
```

To finish the sweep, return the interrupted jobs to `prepared`:

```bash
# Safety net: resolve any job a hard kill left stuck in "running" or "submitting".
./exp.sh job reconcile --group grid

# Move the killed (and failed) jobs back to "prepared".
./exp.sh job reset --group grid
```

You can then re-issue the earlier `./exp.sh submit ...` command to submit a new pilot
job. Its internal `knit submit drain` will continue draining any jobs in a `prepare` state.

Repeat until `job list` shows every `train` job `completed`. To avoid the kill in
the first place on a slow machine, give the pilot more walltime up front (raise
`--walltime`) or fewer grid points.

Note: the calls to `job reconcile` and `job reset` could have been added at the beginning
of the sweep-pilot's body, before `submit drain` is called. These two commands are no-ops
if there is nothing to reconcile or reset.

### 6. Inspect — read the results back

```bash
./exp.sh inspect --group grid
```

### 7. Check timing and node placement

Each `jobs` row records four UTC timestamps — `prepared_at`, `submitted_at`,
`started_at`, and `ended_at`. Read them back with `query sql`, wrapping each
displayed timestamp in `datetime(col, 'localtime')` so the printed value is in
your own time zone:

```bash
./exp.sh query sql --exec \
    "SELECT id, hostnames,
            datetime(started_at, 'localtime') AS started,
            datetime(ended_at,   'localtime') AS ended
       FROM jobs WHERE job = 'train' ORDER BY id"
```

To prove no two sub-jobs ran on the same node at the same time, self-join the
grid on matching `hostnames` and overlapping run windows. An empty result proves
there was no double-booking:

```bash
./exp.sh query sql --exec \
    "SELECT a.id, b.id, a.hostnames
       FROM jobs a JOIN jobs b
         ON a.hostnames = b.hostnames
        AND a.id < b.id
        AND a.started_at < b.ended_at
        AND b.started_at < a.ended_at
      WHERE a.job = 'train' AND b.job = 'train'"
```
