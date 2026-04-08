# Knit integration tests

Integration tests run complete knit experiments inside simulated HPC clusters
(SLURM + OpenMPI, PBS + MPICH) provided by Docker Compose.  They complement the
unit tests in `tests/test_*.sh` by verifying end-to-end behaviour: bootstrap,
setup execution, environment capture, and (once implemented) job submission.

## Prerequisites

- Docker with Compose V2 (`docker compose`)
- ~4 GB free disk space (cluster images are built from source)
- The knit unit tests pass (`make check` from the repo root)

## Directory layout

```
tests/integration/
├── Makefile                          # Test targets
├── lib/
│   ├── assert.sh                     # Assertion helpers sourced by test.sh scripts
│   └── wait-for-cluster.sh           # Polls until the scheduler is ready
├── docker/
│   ├── slurm/                        # SLURM + OpenMPI cluster (Rocky Linux 9)
│   │   ├── Dockerfile
│   │   ├── docker-compose.yml
│   │   ├── conf/                     # slurm.conf, cgroup.conf
│   │   └── scripts/                  # entrypoint-controller.sh, entrypoint-worker.sh
│   └── pbs/                          # PBS + MPICH cluster (Rocky Linux 9)
│       ├── Dockerfile
│       ├── docker-compose.yml
│       └── scripts/                  # entrypoint-server.sh, entrypoint-mom.sh, configure-server.sh
└── experiments/
    ├── 01_bootstrap/                  # Verify bootstrap (sqlite build, DB creation)
    ├── 02_setup_basic/                # Verify setup lifecycle + .activate.sh
    ├── 03_submit_basic/               # [SKIP] Job submission (not yet implemented)
    └── 04_submit_mpi/                 # [SKIP] MPI job (not yet implemented)
```

## Running the tests

From `tests/integration/`:

```bash
# Full cycle on SLURM cluster (build images → wait → run experiments → tear down)
make check-slurm

# Full cycle on PBS cluster
make check-pbs

# Both clusters sequentially
make check-all
```

### Step-by-step (useful for debugging)

```bash
# Start and keep the cluster running
make cluster-up-slurm

# Run all experiments without tearing down afterward
make run-slurm

# Inspect the login node
docker exec -it --user hpcuser slurm-login bash

# Tear down when done
make cluster-down-slurm
```

### Override cluster software versions

```bash
SLURM_VERSION=24.05.2 make check-slurm
PBS_VERSION=24.06.0   make check-pbs
```

## Experiment anatomy

Each experiment lives in `experiments/<name>/` and consists of two scripts:

| File | Purpose |
|------|---------|
| `experiment.sh` | Standard knit experiment (sources `knit.sh`, registers commands, calls `knit $@`) |
| `test.sh` | Test driver: creates a temp workdir, runs the experiment workflow, asserts outcomes |

`test.sh` scripts are executed **inside the cluster login node** as `hpcuser` via
`docker exec`.  They source `lib/assert.sh` for assertion helpers and write their
working directories under `/shared/runs/` (bind-mounted to `docker/<cluster>/shared/`
on the host).

## Cluster details

Both clusters are adapted from `/home/ubuntu/job-managers` (Rocky Linux 9):

| Cluster | Job manager | MPI | Nodes |
|---------|-------------|-----|-------|
| SLURM   | Slurm 24.05.4 | OpenMPI + PMIx | login + 2 compute |
| PBS     | OpenPBS 23.06.06 | MPICH + Hydra | login + 2 compute |

The knit repo root is mounted read-only at `/shared/knit/` inside every container,
so `knit.sh` is always available at `/shared/knit/knit.sh` without rebuilding images.

## Adding a new experiment

1. Create `experiments/<name>/experiment.sh` — a standard knit experiment script
   that sources `/shared/knit/knit.sh`.
2. Create `experiments/<name>/test.sh` — sources `lib/assert.sh`, creates a temp
   workdir, runs the experiment, and calls assertion helpers.
3. Run `make run-slurm` to execute only the new test (all experiments run; the
   existing ones complete quickly).
