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
│   ├── wait-for-cluster.sh           # Polls until the scheduler is ready
│   ├── image-tag.sh                  # Content-hash tag for a cluster's build context
│   ├── provision-image.sh            # Pull prebuilt image (or build locally) before a run
│   └── publish-image.sh              # Push a freshly-built image to ghcr.io (CI/main only)
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
    ├── 03_submit_basic/               # Job submission (knit submit → scheduler)
    ├── 04_submit_mpi/                 # [SKIP] superseded by 09_run_app
    ├── 05_job_killed/                 # Kill detection (cancel → "killed" state)
    ├── 06_job_wait/                   # job wait blocks on the scheduler
    ├── 07_job_cancel/                 # job cancel → scheduler cancel + "killed"
    ├── 08_job_hostnames/              # knit_job_hostnames over a 2-node job
    ├── 09_run_app/                    # knit run: MPI app launch across a job
    └── 10_spack_setup/                # Spack-backed setup (zlib) + job sees it
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

## Continuous integration & image caching

The cluster images are expensive to build from source but change very rarely
(`knit.sh` is bind-mounted, never baked). To avoid rebuilding them on every PR,
`.github/workflows/tests.yml` pulls prebuilt images from the GitHub Container
Registry (`ghcr.io`) and only rebuilds when a Dockerfile actually changes.

**One workflow, two responsibilities:**

- A `unit` job (fast: `make check-unit`) and an `integration` matrix job
  (`[slurm, pbs]`, run in parallel) that provisions its image then runs
  `make -C tests/integration check-<cluster>`.
- On `main` (non-PR events only), after a cluster's suite passes, the workflow
  **publishes** the image it built back to `ghcr.io`, so later runs pull it.

**Three helper scripts** (used identically by CI and by local `make`, so behaviour
never drifts):

| Script | Role |
|--------|------|
| `lib/image-tag.sh <cluster>` | Prints a deterministic content hash of `docker/<cluster>/` (Dockerfile + compose + conf/scripts). The tag *is* the image identity: a registry miss on this tag means "the build context changed, no image was published for it". |
| `lib/provision-image.sh <cluster>` | Pulls `ghcr.io/<owner>/knit-<cluster>-cluster:<hash>` and retags it to the compose image name so `docker compose up -d` reuses it. On any miss (unpublished tag, no access, no owner) it falls back to a **local build**. Records `built`/`pulled` in `lib/.image-state-<cluster>`. **Never pushes.** |
| `lib/publish-image.sh <cluster>` | The only push path. No-ops unless `KNIT_IMAGE_PUBLISH=1` **and** the image was built this run. Pushes `:<hash>` and `:latest`. |

**Correctness on a Dockerfile change.** Changing `docker/<cluster>/**` bumps the
content hash to a tag that hasn't been published yet → the pull misses → the image
is rebuilt locally from the changed Dockerfile. There is no path that tests new
source against a stale image. Fork PRs (which can't publish) rely on this same
local-build fallback.

**Local `make check` is unaffected.** `provision-image.sh` and every `make` target
are pull-or-build only — they never push (a push needs a `GITHUB_TOKEN` that only
exists in CI). Running `make check-slurm` / `make check-pbs` locally with no ghcr
owner configured simply builds the image as before. Optionally, set
`KNIT_IMAGE_OWNER=<gh-user-or-org>` to pull public images locally too.

**Weekly refresh.** A weekly `schedule` (plus manual `workflow_dispatch`) rebuilds
and republishes the images to pick up base-image (`rockylinux:9`) updates, even
though the content hash is unchanged (`KNIT_IMAGE_FORCE_BUILD=1` skips the pull).

**Expected speedup.** On GitHub runners the from-source image builds take about
**7 min (slurm)** and **3 min 45 s (pbs)**; the integration test run itself is
about **20 min**. On a warm PR (Dockerfiles unchanged) each build is replaced by a
`docker pull` of seconds, so the slurm leg saves ~7 min and the pbs leg ~3 min
45 s — and the two clusters now run in parallel instead of sequentially.

## Adding a new experiment

1. Create `experiments/<name>/experiment.sh` — a standard knit experiment script
   that sources `/shared/knit/knit.sh`.
2. Create `experiments/<name>/test.sh` — sources `lib/assert.sh`, creates a temp
   workdir, runs the experiment, and calls assertion helpers.
3. Run `make run-slurm` to execute only the new test (all experiments run; the
   existing ones complete quickly).
