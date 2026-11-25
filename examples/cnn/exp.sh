#!/usr/bin/env bash
#
# =============================================================================
#  knit — tune a CNN image classifier (examples/cnn/exp.sh)
# =============================================================================
#
# This is a complete, runnable knit experiment built around a real machine-
# learning program: the cifar-cnn classifier
# (github.com/knit-sh/image-classifier-example). It trains a small,
# configurable convolutional network on CIFAR-10 or CIFAR-100 and records the
# validation accuracy of every run. It is the companion to Part III of the
# tutorial.
#
# The file exercises six knit features together:
#   - a RESOURCE ("cifar") that downloads and unpacks a CIFAR dataset;
#   - three interchangeable SETUPs (cnnenv-cuda/cpu/xpu) that install cifar-cnn
#     with a PyTorch build matched to the machine's accelerator (hermetic uv
#     wheel-index env for NVIDIA/CPU, a layered env on the site `frameworks`
#     module for Intel GPUs on Aurora), all providing one "cnnenv" ROLE;
#   - a JOB ("train") that trains the network and records the validation
#     accuracy;
#   - a parameter SWEEP: a small exhaustive grid over the architecture shape;
#   - a Bayesian OPTIMIZATION (the ax plugin) over the full parameter set — the tool
#     to reach for when an exhaustive sweep is too costly;
#   - a PILOT JOB that runs a whole ax campaign inside one allocation, scheduling
#     its trials onto the allocation itself instead of the batch scheduler.
#
# The pipeline follows knit's prepare-then-run shape. Each search prepares its
# jobs first (recording them), then runs them:
#
#   bootstrap → fetch → setup ─┬─ sweep prepare → submit drain ──┬─→ inspect
#   provision   data    env    │  (plan the grid)  (run it)      │   read
#   + plugins  (cifar) (cnnenv)└─ ax prepare     → ax optimize ──┘   results
#                                 (plan a campaign) (run trials)
#
# HOW TO USE THIS FILE
# --------------------
# Read the numbered steps below and run them one at a time, from the directory
# that contains this script and knit.sh. The same file runs on a laptop and on
# an HPC login node. On a cluster you describe the site once at `bootstrap` time
# (for example `--profile <name>`, or `--scheduler` / `--account` / `--queue`)
# and add the scheduler options to `submit` (nodes, walltime, ...) as in
# examples/full.sh.
#
# In a hurry? A copy-paste TL;DR of the whole sequence, with a one-line note and
# an expected run time for each command, is at the very end of this file.
#
# Everything knit installs lives under ./.knit, ./setups, ./jobs, ./resources,
# and ./campaigns. Remove it all with:
#   rm -rf .knit setups jobs resources campaigns
#
# -----------------------------------------------------------------------------
# 0. Get knit.sh next to this script
# -----------------------------------------------------------------------------
# This script sources ./knit.sh. Download the single-file knit.sh from a knit
# release and drop it next to cnn.sh, or build it from a checkout with `make`
# (here, examples/knit.sh is already a symlink to the built ../knit.sh).
#
# From here on, all commands are run as ./cnn.sh <command> ...
#
# -----------------------------------------------------------------------------
# 1. bootstrap — provision the tooling
# -----------------------------------------------------------------------------
#
# ```
# ./cnn.sh bootstrap
# ```
#
# Creates ./.knit, makes sqlite and jq available, and — because a uv-backed
# setup and the ax plugin are declared — provisions a knit-private uv and builds
# the ax optimizer environment here, on the login node, where the network is
# reachable. On a cluster, describe the site here too (e.g. --profile <name>).
#
# -----------------------------------------------------------------------------
# 2. fetch — download the CIFAR dataset
# -----------------------------------------------------------------------------
# The `cifar` resource knows its download URL, so one command fetches and unpacks
# it into ./resources/<name>; there is nothing to download by hand (--uncompress
# unpacks the .tar.gz):
#
# ```
# ./cnn.sh fetch --name cifar -- cifar --uncompress
# ```
#
# This gives resources/cifar/cifar-10-batches-py/. For CIFAR-100, fetch a second
# instance with the other URL (see the `cifar` section):
#
# ```
# ./cnn.sh fetch --name cifar100 -- cifar --uncompress \
#       --url https://github.com/knit-sh/image-classifier-example/releases/download/datasets-v1/cifar-100-python.tar.gz
# ```
#
# -----------------------------------------------------------------------------
# 3. setup — build the cnnenv environment
# -----------------------------------------------------------------------------
# Build the uv environment that has cifar-cnn installed, picking the setup type
# that matches the machine's accelerator and naming the instance "cnnenv" (so the
# downstream --setup cnnenv lines are unchanged). A sweep or ax run builds it on
# demand too, but building it now keeps the first search fast and surfaces any
# environment error early:
#
# ```
# ./cnn.sh setup --name cnnenv -- cnnenv-cpu     # or cnnenv-cuda / cnnenv-xpu
# ```
#
# -----------------------------------------------------------------------------
# 4. sweep — run a small exhaustive grid over the architecture shape
# -----------------------------------------------------------------------------
# Prepare one `train` job per point of a {2,3,4} x {3,5} = 6-point grid over
# num-blocks and kernel-size, then run them:
#
# ```
# ./cnn.sh sweep -- prepare --group grid --setup cnnenv -- train --data cifar \
#       --dataset cifar10 --num-blocks '{2,3,4}' --kernel-size '{3,5}'
# ./cnn.sh submit drain --group grid
# ```
#
# The setup is frozen at prepare time, so drain needs no --setup. Add --dry-run
# after `sweep` to print the 6 command lines without recording or running them.
# See the `sweep` section below for the one-shot (ephemeral) form.
#
# -----------------------------------------------------------------------------
# 5. ax — search for the best model with Bayesian optimization
# -----------------------------------------------------------------------------
# When the full parameter set is too large to grid, hand it to the ax optimizer.
# `ax prepare` records a campaign (runs nothing); `ax optimize` then runs the
# ask -> submit -> observe loop, picking each trial's parameters to maximize the
# val_accuracy objective:
#
# ```
# ./cnn.sh ax prepare --campaign tune --objective val_accuracy --maximize \
#       --max-trials 12 --sobol-trials 4 --seed 1 \
#       -- submit --setup cnnenv -- train --data cifar --dataset cifar10 \
#          --num-blocks @domain --base-channels @domain --kernel-size @domain \
#          --dropout @domain --activation @domain --residual @domain \
#          --lr @domain --batch-size @domain
# ./cnn.sh ax optimize --campaign tune
# ```
#
# -----------------------------------------------------------------------------
# 6. pilot — run the whole ax campaign inside one allocation (optional)
# -----------------------------------------------------------------------------
# On a cluster, step 5 submits one `train` job per trial to the batch scheduler,
# which queues each separately. To run the whole campaign inside a single
# allocation instead, prepare the campaign and submit the `tune-pilot` job: its
# body runs `ax optimize --max-inflight N`, so every trial it submits is packed
# onto the pilot's nodes by the in-allocation daemon, up to N at a time:
#
# ```
# ./cnn.sh ax prepare --campaign tune-p --objective val_accuracy --maximize \
#       --max-trials 12 --sobol-trials 4 --seed 1 \
#       -- submit --setup cnnenv -- train --data cifar --dataset cifar10 \
#          --num-blocks @domain --base-channels @domain --kernel-size @domain \
#          --dropout @domain --activation @domain --residual @domain \
#          --lr @domain --batch-size @domain
# ./cnn.sh submit --nodes 4 --wait -- tune-pilot --campaign tune-p --max-inflight 4
# ```
#
# -----------------------------------------------------------------------------
# 7. inspect — read the results back
# -----------------------------------------------------------------------------
# List the campaign and its best trial:
#
# ```
# ./cnn.sh ax list
# ./cnn.sh ax show --campaign tune
# ```
#
# Rank every run of a group by accuracy with the experiment's own `inspect`
# command (it runs the join for you; pass a sweep group or a campaign name):
#
# ```
# ./cnn.sh inspect --group grid
# ./cnn.sh inspect --group tune
# ```
#
# -----------------------------------------------------------------------------
# 8. resume — continue a campaign the walltime cut short
# -----------------------------------------------------------------------------
# A long optimization may not finish inside its job's wall-clock limit. The pilot
# in step 6 runs under the site walltime (on a laptop, the one-hour default), so
# a 12-trial campaign can be stopped before it reaches its budget. When that
# happens the scheduler signals the job, ax records the campaign "interrupted"
# with the trials it had already finished, and the run is resumable. Check how
# far it got:
#
# ```
# ./cnn.sh ax show --campaign tune-p
# ```
#
# A status of "interrupted" with fewer than 12 trials done means the walltime
# stopped it. Resume by submitting the pilot again at the SAME campaign: ax reads
# the persisted state, keeps the trials already done, and continues the rest.
# Give it more walltime so it can finish, and repeat until "ax show" reports
# "completed":
#
# ```
# ./cnn.sh submit --walltime 06:00:00 --nodes 4 --wait -- tune-pilot --campaign tune-p --max-inflight 4
# ```
#
# A plain (non-pilot) campaign such as `tune` resumes the same way, directly:
#
# ```
# ./cnn.sh ax optimize --campaign tune
# ```
#
# Run from the directory that contains this script and knit.sh, as
# ./cnn.sh <command> ...
# -----------------------------------------------------------------------------

# Source knit.sh. This requires knit.sh to sit next to this script: the re-entry
# paths (submit, run) arrange for the experiment to be sourced from the script's
# directory, so this bare form resolves even though a job body runs elsewhere.
source knit.sh

# uv and ax ship as plugins. Importing uv adds the uv environment manager used by
# the `cnnenv` setups below (@with_uv_env for the hermetic cuda/cpu envs,
# @with_uv_specs + @with_uv_layered for the Aurora xpu env) and the --uv bootstrap
# option. Importing ax adds the `ax` optimizer commands; ax imports uv in turn.
# Both are pinned to their released tags; the resolved commits freeze in
# .knit/plugins.lock.
knit_import uv@v1.0.0
knit_import ax@v1.0.0

knit_set_program_description \
    "Tune a CNN image classifier on CIFAR-10/100 with a sweep and Bayesian optimization."

# -----------------------------------------------------------------------------
# cnnenv (walkthrough step 3) — the environment(s) that install the classifier.
#
# cnnenv is a Python environment with cifar-cnn installed and a PyTorch build
# matched to the machine's accelerator. The one thing that differs between
# platforms is where PyTorch comes from; everything else — the train job, the
# sweep, the ax campaign — is identical across machines. Rather than one setup
# with a branch inside its body, that difference is expressed as THREE
# declarative setups, each built entirely by the uv plugin (no hand-written
# body), that all provide the same ROLE "cnnenv":
#
#   - cnnenv-cuda / cnnenv-cpu: a self-contained (hermetic) uv environment, with
#     torch+torchvision pinned to the matching PyTorch wheel index
#     (download.pytorch.org/whl/<cu121|cpu>); uv resolves the whole stack on a
#     managed Python, reproducible on any machine.
#   - cnnenv-xpu (Aurora): a LAYERED uv environment built on the site `frameworks`
#     module's Python (--system-site-packages), installing cifar-cnn --no-deps so
#     the module's XPU torch is not replaced by a PyPI wheel. (Verified on Aurora:
#     frameworks ships torch 2.13 + torchvision 0.28 + PIL.)
#
# The three are interchangeable from the job's point of view — each puts cifar-cnn
# on PATH — so the `train` job requires the ROLE "cnnenv" (@with_setup "cnnenv")
# and accepts an instance of any of the three. That is the portability story made
# concrete: one experiment, one setup choice per site. The train job pins the
# device it asks for (--device, recorded as an input); the program fails hard if
# that device is absent, so a run can never silently fall back to the CPU and
# record a misleading result.
#
# Build the instance that fits the machine, NAMING it "cnnenv" so every downstream
# `--setup cnnenv` line below refers to it unchanged (the instance name is free;
# the role comes from its type):
#   ./cnn.sh setup --name cnnenv -- cnnenv-cpu    # laptop / CPU (default)
#   ./cnn.sh setup --name cnnenv -- cnnenv-cuda   # NVIDIA GPU
#   ./cnn.sh setup --name cnnenv -- cnnenv-xpu    # Intel GPU (Aurora)
#
# NOTE: for the layered cnnenv-xpu, `python` must be the module's interpreter at
# build time; the Aurora `frameworks` module (in the machine profile) provides it.
# The hermetic cuda/cpu setups need no system Python — uv downloads a managed one.
# -----------------------------------------------------------------------------
# cnnenv-cuda / cnnenv-cpu: a hermetic uv environment. The pyproject pins
# torch+torchvision to the matching PyTorch wheel index via [tool.uv.index]; uv
# resolves and installs the whole stack on a managed Python, with no hand-written
# body. cifar-cnn comes from its git repository as a direct reference.
@setup "cnnenv-cuda" "cifar-cnn in a hermetic uv env with CUDA PyTorch (wheel index)."
@with_uv_env <<'TOML'
[project]
name = "cnnenv"
version = "0.0.0"
requires-python = ">=3.11"
dependencies = [
    "torch",
    "torchvision",
    "pillow",
    "cifar-cnn @ git+https://github.com/knit-sh/image-classifier-example.git",
]

[tool.uv.sources]
torch = { index = "pytorch" }
torchvision = { index = "pytorch" }

[[tool.uv.index]]
name = "pytorch"
url = "https://download.pytorch.org/whl/cu121"
explicit = true
TOML
@provides_setup_role "cnnenv"
@empty
@done

@setup "cnnenv-cpu" "cifar-cnn in a hermetic uv env with CPU PyTorch (wheel index)."
@with_uv_env <<'TOML'
[project]
name = "cnnenv"
version = "0.0.0"
requires-python = ">=3.11"
dependencies = [
    "torch",
    "torchvision",
    "pillow",
    "cifar-cnn @ git+https://github.com/knit-sh/image-classifier-example.git",
]

[tool.uv.sources]
torch = { index = "pytorch" }
torchvision = { index = "pytorch" }

[[tool.uv.index]]
name = "pytorch"
url = "https://download.pytorch.org/whl/cpu"
explicit = true
TOML
@provides_setup_role "cnnenv"
@empty
@done

# cnnenv-xpu (Aurora): a LAYERED uv environment. torch+torchvision+XPU come from
# the site `frameworks` module (loaded by the machine profile, modules:
# ["frameworks"]); @with_uv_layered builds the venv --system-site-packages on
# that module's Python, and @with_uv_no_deps installs cifar-cnn without pulling a
# PyPI torch over the module's XPU build.
@setup "cnnenv-xpu" "cifar-cnn layered on the Aurora frameworks module (Intel XPU)."
@with_uv_specs "cifar-cnn @ git+https://github.com/knit-sh/image-classifier-example.git"
@with_uv_layered
@with_uv_no_deps
@provides_setup_role "cnnenv"
@empty
@done

# -----------------------------------------------------------------------------
# cifar (walkthrough step 2) — a resource that downloads a CIFAR dataset.
#
# @with_url declares a downloadable resource: `knit fetch` downloads the URL and,
# with --uncompress, unpacks the archive into ./resources/<name>. The default URL
# is the CIFAR-10 python archive, so the unpacked instance holds
# cifar-10-batches-py/ — exactly what `cifar-cnn --data` expects.
#
# Fetch the default (CIFAR-10) instance (--uncompress unpacks the .tar.gz):
#   ./cnn.sh fetch --name cifar -- cifar --uncompress
#
# The URL is just a default; override it to fetch CIFAR-100 as a second instance
# of the same resource type:
#   ./cnn.sh fetch --name cifar100 -- cifar --uncompress \
#       --url https://github.com/knit-sh/image-classifier-example/releases/download/datasets-v1/cifar-100-python.tar.gz
#
# The `train` job reads the fetched directory through knit_resource_path; its
# --data option names the instance and --dataset tells cifar-cnn which loader to
# use (so --data cifar --dataset cifar10, or --data cifar100 --dataset cifar100).
# -----------------------------------------------------------------------------
@resource "cifar" "A CIFAR dataset, downloaded and unpacked (default: CIFAR-10)."
@with_url "https://github.com/knit-sh/image-classifier-example/releases/download/datasets-v1/cifar-10-python.tar.gz"
@done

# -----------------------------------------------------------------------------
# train (walkthrough steps 4-5) — the job that trains one network and records
# its validation accuracy.
#
# The job declares the cnnenv setup (so cifar-cnn is on PATH) and the cifar
# resource (so the datasets are staged). Its body does NOT run `cifar-cnn`
# directly: it launches the `cifar-cnn-train` app through `knit run` (one rank on
# the job's allocated node), captures the app's output, reads the machine-readable
# "RESULT val_accuracy=..." line back, and re-records it with knit_output. Going
# through `knit run` is what places the training on the assigned node; under a
# pilot the sub-job body itself runs on the launch node, so a bare `cifar-cnn`
# call would never reach the node the daemon set aside for it (see the
# cifar-cnn-train section). That recorded column is the objective the sweep ranks
# and the ax optimizer maximizes.
#
# Every parameter the sweep or the optimizer can vary carries a --domain descriptor:
# a set {a,b,c} of discrete values, or a range [lo..hi]. --dataset and --epochs
# have no domain: the dataset is fixed per run, and epochs stay small so a run
# finishes fast. There is deliberately NO @with_table here: @job already
# declares the job's own table, and that is where the optimizer reads the
# objective; a bare @with_table would point recording at a different table.
#
# Train once (build the setup first; see the cnnenv section):
#   ./cnn.sh setup  --name cnnenv -- cnnenv-cpu   # or cnnenv-cuda / cnnenv-xpu
#   ./cnn.sh submit --setup cnnenv --wait -- train --data cifar --epochs 3
# -----------------------------------------------------------------------------
@job "train" "Train the CNN and record its validation accuracy."
@with_setup    "cnnenv"
@with_resource "data:cifar" "Name of the fetched CIFAR instance (match --dataset)."
@with_optional "dataset:string"        "cifar10" "Dataset to train on: cifar10 or cifar100."
@with_optional "num-blocks:integer"    "3"       "Convolution blocks (max 5)."            --domain '[1..5]'
@with_optional "base-channels:integer" "32"      "Channels in the first block."           --domain '{16,32,64}'
@with_optional "kernel-size:integer"   "3"       "Convolution kernel size."               --domain '{3,5}'
@with_optional "dropout:real"          "0.3"     "Dropout before the classifier head."    --domain '[0.0..0.5]'
@with_optional "activation:string"     "relu"    "Activation function."                   --domain '{relu,gelu,leaky-relu}'
@with_optional "residual:string"       "false"   "Residual skip connections."             --domain '{false,true}'
@with_optional "lr:real"               "0.001"   "Initial learning rate."                 --domain '[0.0001..0.1]'
@with_optional "batch-size:integer"    "128"     "Mini-batch size."                       --domain '{32,64,128,256}'
@with_optional "epochs:integer"        "3"       "Training epochs (not searched)."
@with_optional "device:string"         "auto"    "Requested compute device: auto, cpu, cuda, or xpu (an explicit cuda/xpu fails if absent)."
@with_output   "val_accuracy:real" "Final-epoch validation accuracy (%)." --unset "0"
_train_job() {
    # Resolve the staged dataset directory and where to write the model.
    local datadir model out acc
    datadir="$(knit_resource_path "$(knit_get_parameter data "$@")")"
    model="${KNIT_JOB_PREFIX%/}/model.pt"

    # Launch the training through `knit run` as the cifar-cnn-train app, one rank
    # placed on the job's allocated node. Launching it this way (not a bare
    # `cifar-cnn` call) is what puts the work on the assigned node — essential
    # under a pilot, where the sub-job body itself runs on the launch node. The
    # app streams progress to its stderr (shown live) and prints just the metric
    # line to stdout, which `knit run` forwards here for capture. --residual is
    # passed through verbatim; the app turns it into the bare flag.
    out="$(knit run --procs 1 --procs-per-node 1 -- cifar-cnn-train \
        --model         "${model}" \
        --datadir       "${datadir}" \
        --dataset       "$(knit_get_parameter dataset "$@")" \
        --num-blocks    "$(knit_get_parameter num-blocks "$@")" \
        --base-channels "$(knit_get_parameter base-channels "$@")" \
        --kernel-size   "$(knit_get_parameter kernel-size "$@")" \
        --dropout       "$(knit_get_parameter dropout "$@")" \
        --activation    "$(knit_get_parameter activation "$@")" \
        --residual      "$(knit_get_parameter residual "$@")" \
        --lr            "$(knit_get_parameter lr "$@")" \
        --batch-size    "$(knit_get_parameter batch-size "$@")" \
        --epochs        "$(knit_get_parameter epochs "$@")" \
        --device        "$(knit_get_parameter device "$@")")"

    # The cifar-cnn-train app recorded val_accuracy on its own row; re-emit it
    # here so the objective also lives on the `train` row, where the sweep ranks
    # it, the ax optimizer reads it, and `inspect` joins on it. The device is an
    # input (--device), honored or the run fails, so there is no separate "device
    # used" to record.
    acc="$(grep -oE 'RESULT val_accuracy=[0-9.]+' <<<"${out}" | tail -1 | cut -d= -f2)"
    knit_output "val_accuracy" "${acc:-0}"
}
@done

# -----------------------------------------------------------------------------
# cifar-cnn-train — the app the `train` job launches through `knit run`.
#
# This app is the unit `knit run` places on a node: its body runs one
# `cifar-cnn train`. `train` launches it rather than calling `cifar-cnn`
# directly so the work lands on the node the scheduler — or, inside a pilot, the
# in-allocation daemon — assigned to the job. That is the load-bearing rule: a
# pilot sub-job's body runs on the pilot's LAUNCH node, and only work launched
# through `knit run` (which reads the daemon's per-job node assignment) reaches
# the node set aside for it. A bare `cifar-cnn` call would run on the launch node
# and, with several trials in flight, pile them all onto it, contending for its
# one GPU. The app mirrors the julia `render` app.
#
# It takes one rank (--procs 1): a single training process, not a data-parallel
# job. It declares no setup — an app inherits the launching job's activated
# cnnenv environment, so `cifar-cnn` is already on PATH. It records val_accuracy
# on its own row and echoes the metric line on stdout so the `train` job can read
# it back (training progress goes to stderr, shown live).
# -----------------------------------------------------------------------------
@app "cifar-cnn-train" "Train the CNN on the assigned node and record its accuracy."
@with_required "model:string"           "Absolute path for the trained model (the job supplies one)."
@with_required "datadir:string"         "Absolute path of the staged dataset directory."
@with_optional "dataset:string"        "cifar10" "Dataset to train on: cifar10 or cifar100."
@with_optional "num-blocks:integer"    "3"       "Convolution blocks (max 5)."
@with_optional "base-channels:integer" "32"      "Channels in the first block."
@with_optional "kernel-size:integer"   "3"       "Convolution kernel size."
@with_optional "dropout:real"          "0.3"     "Dropout before the classifier head."
@with_optional "activation:string"     "relu"    "Activation function."
@with_optional "residual:string"       "false"   "Residual skip connections (true or false)."
@with_optional "lr:real"               "0.001"   "Initial learning rate."
@with_optional "batch-size:integer"    "128"     "Mini-batch size."
@with_optional "epochs:integer"        "3"       "Training epochs."
@with_optional "device:string"         "auto"    "Requested compute device: auto, cpu, cuda, or xpu."
@with_output   "val_accuracy:real" "Final-epoch validation accuracy (%)." --unset "0"
_cifar_cnn_train_app() {
    # Report where the launcher placed this rank (on stderr, so it stays out of
    # the metric line the job captures on stdout). Under a pilot this is the node
    # the daemon assigned to the job via knit run, not the pilot's launch node.
    printf 'cifar-cnn-train running on host: %s\n' "$(hostname)" >&2

    # The program takes --residual as a bare flag, so turn the true/false value
    # into the flag's presence or absence.
    local -a resflag=()
    [[ "$(knit_get_parameter residual "$@")" == "true" ]] && resflag=(--residual)

    # Train, merging stderr into stdout and teeing to stderr so progress streams
    # live (the launcher forwards this rank's stderr to the job) while the full
    # output is captured for parsing.
    local out acc
    out="$(cifar-cnn train \
        --model         "$(knit_get_parameter model "$@")" \
        --dataset       "$(knit_get_parameter dataset "$@")" \
        --data          "$(knit_get_parameter datadir "$@")" \
        --num-blocks    "$(knit_get_parameter num-blocks "$@")" \
        --base-channels "$(knit_get_parameter base-channels "$@")" \
        --kernel-size   "$(knit_get_parameter kernel-size "$@")" \
        --dropout       "$(knit_get_parameter dropout "$@")" \
        --activation    "$(knit_get_parameter activation "$@")" \
        "${resflag[@]}" \
        --lr            "$(knit_get_parameter lr "$@")" \
        --batch-size    "$(knit_get_parameter batch-size "$@")" \
        --epochs        "$(knit_get_parameter epochs "$@")" \
        --device        "$(knit_get_parameter device "$@")" \
        2>&1 | tee -a /dev/stderr)"

    # Read the machine-readable metric line and record it on this app's row. Knit
    # records outputs from rank 0 only, so one knit_output writes one row.
    acc="$(grep -oE 'RESULT val_accuracy=[0-9.]+' <<<"${out}" | tail -1 | cut -d= -f2)"
    knit_output "val_accuracy" "${acc:-0}"

    # Emit just the metric as a clean machine-readable line on stdout, which
    # `knit run` forwards to the launching job (the training log above went to
    # stderr, so the job's capture sees only this line).
    printf 'RESULT val_accuracy=%s\n' "${acc:-0}"
}
@done

# -----------------------------------------------------------------------------
# sweep (walkthrough step 4) — an exhaustive grid over the architecture shape.
#
# There is nothing to register here: a sweep runs the existing `train` job once
# per point of a cartesian product. Each parameter takes sweep-syntax in place of a
# value — a set '{a,b,c}' of explicit values, or '@domain' to draw from the parameter's
# declared --domain. Here the grid is num-blocks x kernel-size = {2,3,4} x {3,5},
# six points; every other parameter keeps its default.
#
# Durable form (recommended): `prepare` records one job per point in the `grid`
# group without running anything, then `submit drain` runs the whole group. The
# setup, options, and run arguments are frozen at prepare time — so --setup goes
# on the `prepare` line and drain needs none. The jobs persist, so you can
# inspect the plan, drain in several passes, and retry failures:
#   ./cnn.sh sweep -- prepare --group grid --setup cnnenv -- train --data cifar \
#       --dataset cifar10 --num-blocks '{2,3,4}' --kernel-size '{3,5}'
#   ./cnn.sh submit drain --group grid
#
# Ephemeral form (one shot): submit and run every point immediately, nothing is
# staged first. --max-inflight keeps several in flight at once:
#   ./cnn.sh sweep --max-inflight 2 -- submit --group grid --setup cnnenv --wait \
#       -- train --data cifar --dataset cifar10 \
#          --num-blocks '{2,3,4}' --kernel-size '{3,5}'
#
# Preview either form without recording or running by inserting --dry-run right
# after `sweep`; it prints the six reconstructed command lines and exits:
#   ./cnn.sh sweep --dry-run -- submit -- train --data cifar --dataset cifar10 \
#       --num-blocks '{2,3,4}' --kernel-size '{3,5}'
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# ax (walkthrough step 5) — Bayesian optimization over the full parameter set.
#
# The sweep above is exhaustive: its cost is the product of every axis, so it
# only scales to a couple of small ones. To search the whole parameter set — eight
# dimensions here — hand the problem to the ax plugin, which models the
# objective and proposes the next trial instead of trying every combination.
#
# Like the sweep, this registers nothing new; it drives the existing `train`
# job. Each parameter to search takes the value '@domain', which tells ax to treat it
# as a search dimension and draw from the parameter's declared --domain (the sets and
# ranges on the `train` options above). Parameters left at a plain value stay fixed.
#
# `ax prepare` records the campaign but runs no trials: it names the campaign,
# the objective column (val_accuracy) and its direction (--maximize), the
# campaign's lifetime trial budget (--max-trials), the quasi-random warm-up
# (--sobol-trials), and the RNG --seed for reproducibility. Concurrency is not
# set here: it is a per-call option of `ax optimize` (--max-inflight). The
# downstream is an ordinary `submit` line, so --setup cnnenv goes there just
# as for a single run:
#   ./cnn.sh ax prepare --campaign tune --objective val_accuracy --maximize \
#       --max-trials 12 --sobol-trials 4 --seed 1 \
#       -- submit --setup cnnenv -- train --data cifar --dataset cifar10 \
#          --num-blocks @domain --base-channels @domain --kernel-size @domain \
#          --dropout @domain --activation @domain --residual @domain \
#          --lr @domain --batch-size @domain
#
# `ax optimize` then runs the loop. The plugin's private uv-backed Ax environment
# was built back at `bootstrap` (on the login node, where the network is
# reachable), so optimize needs no network: it submits one `train` job per trial
# under the campaign's group, reads back val_accuracy, and asks Ax for the next
# point until the budget is spent. It is resumable: interrupt it and run the same
# command again to continue from the persisted state.
#   ./cnn.sh ax optimize --campaign tune
#
# Trial runtimes can spread widely. Some parameters change the training cost: a small
# --batch-size does more steps per epoch, and a large --base-channels or
# --num-blocks makes a heavier network. The search draws these parameters freely, so
# one trial can take many times longer than another (here, from under 2 minutes
# to about 30). Size the --max-trials budget and the wall time for the slow end,
# not the average.
#
# Inspect the campaign with `ax list`, `ax show --campaign tune`, or the
# recorded rows (see the inspect section).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# tune-pilot (walkthrough step 6) — run an ax campaign inside one pilot job.
#
# `ax optimize` (step 5) submits one `train` job per trial. Run from a login
# node, each submit goes to the batch scheduler, so a long campaign queues many
# separate jobs. A pilot job avoids that: it takes one allocation, starts the
# in-allocation knit-pilotd daemon over its nodes, and from inside its body every
# `knit submit` is packed onto that allocation by the daemon instead of reaching
# the batch scheduler.
#
# @with_pilot makes this job a pilot. Its body just runs `ax optimize`, so the
# trial jobs the ax loop submits become the pilot's sub-jobs. The pilot trains
# nothing itself, so it declares no setup; each trial job still carries
# --setup cnnenv (frozen into the campaign at prepare time) and re-hydrates the
# environment on its assigned node. The pilot's `ax optimize --max-inflight` sets
# how many trials pack onto the allocation at once.
#
# Submit it over as many nodes as that concurrency needs:
#   ./cnn.sh submit --nodes 4 --wait -- tune-pilot --campaign tune-p --max-inflight 4
# -----------------------------------------------------------------------------
@job "tune-pilot" "Optimize an ax campaign inside one pilot allocation."
@without_setup
@with_pilot
@with_optional "campaign:string" "tune" "Name of a prepared ax campaign to optimize."
@with_optional "max-inflight:integer" "4" "Trials to keep in flight on the pilot's nodes."
_tune_pilot_job() {
    # Inside the pilot allocation the daemon is live, so the `knit submit` calls
    # that `ax optimize` issues for each trial are scheduled onto this
    # allocation's nodes rather than sent to the batch scheduler.
    knit ax optimize \
        --campaign     "$(knit_get_parameter campaign "$@")" \
        --max-inflight "$(knit_get_parameter max-inflight "$@")"
}
@done

# -----------------------------------------------------------------------------
# sweep-pilot — run a prepared sweep group inside one pilot allocation.
#
# The sweep's `submit drain` (step 4) sends one job per grid point to the batch
# scheduler, which queues each separately. This pilot avoids that the same way
# tune-pilot does for ax: it takes one allocation, starts the knit-pilotd daemon
# over its nodes, and from inside its body `submit drain` releases the prepared
# group onto that allocation instead of the batch scheduler. The jobs were frozen
# with --setup cnnenv at prepare time, so the pilot itself declares no setup.
#
# Prepare the group at one node per job, then submit the pilot over as many nodes
# as the concurrency needs (--max-inflight packs that many jobs onto the nodes):
#   ./cnn.sh sweep -- prepare --group grid --setup cnnenv --nodes 1 \
#       -- train --data cifar --dataset cifar10 \
#          --num-blocks '{2,3,4}' --kernel-size '{3,5}'
#   ./cnn.sh submit --nodes 2 --wait -- sweep-pilot --group grid --max-inflight 2
# -----------------------------------------------------------------------------
@job "sweep-pilot" "Drain a prepared job group inside one pilot allocation."
@without_setup
@with_pilot
@with_optional "group:string"         "grid" "Prepared job group to drain onto the pilot."
@with_optional "max-inflight:integer" "2"    "Jobs to keep in flight on the pilot's nodes."
_sweep_pilot_job() {
    # Inside the pilot allocation the daemon is live, so the `knit submit` that
    # `submit drain` issues for each prepared job is packed onto this allocation's
    # nodes rather than sent to the batch scheduler.
    knit submit drain \
        --group        "$(knit_get_parameter group "$@")" \
        --max-inflight "$(knit_get_parameter max-inflight "$@")"
}
@done

# -----------------------------------------------------------------------------
# inspect (walkthrough step 7) — read the recorded results back.
#
# knit records every run, so you query the database. The campaign commands give
# the quick view:
#   ./cnn.sh ax list                   # one line per campaign: trials and best
#   ./cnn.sh ax show --campaign tune    # objective, budget, best, and the command
#
# For the per-run numbers, this experiment ships an `inspect` command so you do
# not have to write SQL by hand. It ranks one group's runs (a sweep group like
# `grid`, or a campaign name like `tune`) by validation accuracy, with each run's
# parameters and wall time:
#   ./cnn.sh inspect --group grid
#   ./cnn.sh inspect --group tune
#
# The query behind it joins two tables. Each `train` run records its parameters and
# val_accuracy in the `train` table. A sweep point or an ax trial is launched
# through `submit`, so its group label lives on the `jobs` row, not the `train`
# row. The two rows have different ids, tied together by a `call` edge in the
# `__provenance__` table (the submit job calls the train body); the join walks
# that edge, and the run's wall time comes from the edge's start/end times.
# -----------------------------------------------------------------------------
@command "inspect" "Rank a group's training runs by validation accuracy."
@with_optional "group:string" "tune" "Sweep group or campaign name to rank (e.g. grid, tune)."
_inspect_cmd() {
    local group
    group="$(knit_get_parameter group "$@")"
    knit query sql --format column --header --exec "
        SELECT t.num_blocks   AS nb,
               t.kernel_size   AS ks,
               t.base_channels AS bc,
               t.batch_size    AS bs,
               t.activation    AS act,
               round(t.lr, 4)  AS lr,
               t.val_accuracy  AS acc,
               CAST(CAST(p.end_time AS REAL) - CAST(p.start_time AS REAL) AS INT) AS secs
        FROM train t
        JOIN __provenance__ p ON p.target_id = t.id AND p.edge_type = 'call'
        WHERE p.source_id IN (SELECT id FROM jobs WHERE \"group\" = '${group}')
        ORDER BY t.val_accuracy DESC"
}
@done

# -----------------------------------------------------------------------------
# Call the main entry point of the knit framework (must come last).
# -----------------------------------------------------------------------------
knit "$@"

# =============================================================================
#  TL;DR — the whole walkthrough, copy-paste order
# =============================================================================
# Run from this directory (examples/). Times are from one CPU-only laptop run on
# CIFAR-10 with the default 3 epochs; they scale with your machine and network.
#
#   # get knit.sh next to this script: download a knit release, or build it with
#   # `make` from a checkout (here examples/knit.sh is a symlink to ../knit.sh)
#
#   # provision sqlite, jq, the private uv, and the Ax env (~5 min; downloads torch + Ax)
#   # on a cluster, add the site options here (e.g. --profile <name>)
#   ./cnn.sh bootstrap
#
#   # download and unpack the CIFAR-10 dataset (~1-2 min; depends on your link)
#   ./cnn.sh fetch --name cifar -- cifar --uncompress
#
#   # build the uv environment with cifar-cnn installed (~2 min; torch from the uv cache)
#   # pick the type for your accelerator: cnnenv-cpu (laptop), cnnenv-cuda, or cnnenv-xpu
#   ./cnn.sh setup --name cnnenv -- cnnenv-cpu
#
#   # prepare the 6-point num-blocks x kernel-size sweep (instant; records 6 jobs)
#   ./cnn.sh sweep -- prepare --group grid --setup cnnenv -- train --data cifar \
#       --dataset cifar10 --num-blocks '{2,3,4}' --kernel-size '{3,5}'
#
#   # run the sweep (~22 min; 6 jobs x 3 epochs)
#   ./cnn.sh submit drain --group grid
#
#   # prepare the 12-trial Bayesian optimization over the full parameter set (instant)
#   ./cnn.sh ax prepare --campaign tune --objective val_accuracy --maximize \
#       --max-trials 12 --sobol-trials 4 --seed 1 \
#       -- submit --setup cnnenv -- train --data cifar --dataset cifar10 \
#          --num-blocks @domain --base-channels @domain --kernel-size @domain \
#          --dropout @domain --activation @domain --residual @domain \
#          --lr @domain --batch-size @domain
#
#   # run the optimization (~2 h; trial cost varies widely, ~1.5 to 30 min each)
#   ./cnn.sh ax optimize --campaign tune
#
#   # read the results back (instant)
#   ./cnn.sh ax show --campaign tune       # campaign summary and best trial
#   ./cnn.sh inspect --group tune           # every trial ranked by accuracy
#
# Optional, on a cluster: run a campaign inside one allocation (step 6). Prepare
# it with parallelism, then submit the pilot over several nodes so trials overlap:
#
#   # prepare a parallel campaign (instant)
#   ./cnn.sh ax prepare --campaign tune-p --objective val_accuracy --maximize \
#       --max-trials 12 --sobol-trials 4 --seed 1 \
#       -- submit --setup cnnenv -- train --data cifar --dataset cifar10 \
#          --num-blocks @domain --base-channels @domain --kernel-size @domain \
#          --dropout @domain --activation @domain --residual @domain \
#          --lr @domain --batch-size @domain
#
#   # run the whole campaign inside one 4-node pilot allocation (minutes to hours)
#   ./cnn.sh submit --nodes 4 --wait -- tune-pilot --campaign tune-p --max-inflight 4
# =============================================================================
