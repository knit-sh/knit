#!/bin/bash

# doc-check: source-only
#
# The complete Part III experiment in one file: a uv-backed setup that installs
# the cifar-cnn classifier, a cifar resource, the train job with its full
# eight-parameter search space, and the two pilot jobs --- sweep-pilot (drains a
# prepared grid, resumable) and tune-pilot (runs an ax campaign). This is the
# final state of the experiment built up over Steps 1--8.
#
# Source-only: training needs uv, the dataset, and real compute, pilots need a
# scheduler, and "ax optimize" drives a real Ax environment, none of which run in
# plain CI, so check-docs only syntax-checks this file. Behavior was validated
# end to end during development; the ax loop's convergence is covered live by the
# 40_ax_optimize integration test.

source knit.sh

# uv and ax ship as plugins. Importing uv adds the uv environment manager the
# setup uses; importing ax adds the `ax` optimizer commands (ax imports uv too).
knit_import uv
knit_import ax

knit_set_program_description \
    "Tune a CNN image classifier on CIFAR-10 with a sweep and Bayesian optimization."

# --- Setup ------------------------------------------------------------------
# A uv environment with the cifar-cnn classifier installed from its git repo.
@setup "cnnenv" "A uv environment with the cifar-cnn classifier installed."
@with_uv_specs "cifar-cnn @ git+https://github.com/knit-sh/image-classifier-example.git"
@empty
@done

# --- Resource ---------------------------------------------------------------
# The CIFAR-10 dataset, downloaded and unpacked by `knit fetch`.
@resource "cifar" "The CIFAR-10 dataset, downloaded and unpacked."
@with_url "https://www.cs.toronto.edu/~kriz/cifar-10-python.tar.gz"
@done

# --- Job: train -------------------------------------------------------------
# Trains one architecture and records its validation accuracy. Every searchable
# parameter carries a --domain; dataset and epochs are fixed.
@job "train" "Train the CNN and record its validation accuracy."
@with_setup    "cnnenv"
@with_resource "data:cifar" "Name of the fetched CIFAR instance."
@with_optional "dataset:string"        "cifar10" "Dataset loader (not searched)."
@with_optional "num-blocks:integer"    "3"       "Convolution blocks."          --domain '[1..5]'
@with_optional "base-channels:integer" "32"      "Channels in the first block." --domain '{16,32,64}'
@with_optional "kernel-size:integer"   "3"       "Convolution kernel size."     --domain '{3,5}'
@with_optional "dropout:real"          "0.3"     "Dropout before the classifier head." --domain '[0.0..0.5]'
@with_optional "activation:string"     "relu"    "Activation function."                --domain '{relu,gelu,leaky-relu}'
@with_optional "residual:string"       "false"   "Residual skip connections."          --domain '{false,true}'
@with_optional "lr:real"               "0.001"   "Initial learning rate."              --domain '[0.0001..0.1]' --log
@with_optional "batch-size:integer"    "128"     "Mini-batch size."                    --domain '{32,64,128,256}'
@with_optional "epochs:integer"        "3"       "Training epochs (not searched)."
@with_output   "val_accuracy:real"     "0"       "Final-epoch validation accuracy (%)."
_train_job() {
    local datadir dataset residual out acc
    datadir="$(knit_resource_path "$(knit_get_parameter data "$@")")"
    dataset="$(knit_get_parameter dataset "$@")"

    local -a resflag=()
    residual="$(knit_get_parameter residual "$@")"
    [[ "${residual}" == "true" ]] && resflag=(--residual)

    out="$(cifar-cnn train \
        --model         "${KNIT_JOB_PREFIX%/}/model.pt" \
        --dataset       "${dataset}" \
        --data          "${datadir}" \
        --num-blocks    "$(knit_get_parameter num-blocks "$@")" \
        --base-channels "$(knit_get_parameter base-channels "$@")" \
        --kernel-size   "$(knit_get_parameter kernel-size "$@")" \
        --dropout       "$(knit_get_parameter dropout "$@")" \
        --activation    "$(knit_get_parameter activation "$@")" \
        "${resflag[@]}" \
        --lr            "$(knit_get_parameter lr "$@")" \
        --batch-size    "$(knit_get_parameter batch-size "$@")" \
        --epochs        "$(knit_get_parameter epochs "$@")" \
        2>&1 | tee /dev/stderr)"

    acc="$(grep -oE 'RESULT val_accuracy=[0-9.]+' <<<"${out}" | tail -1 | cut -d= -f2)"
    knit_output "val_accuracy" "${acc:-0}"
}
@done

# --- Job: sweep-pilot -------------------------------------------------------
# Drains a prepared sweep inside one allocation, resuming across walltime
# windows: job reconcile -> job reset -> submit drain. The drain's --max-inflight
# is sized to the pilot's node count (one single-node `train` per node) so the
# whole allocation works at once instead of one job at a time.
@job "sweep-pilot" "Drain a prepared sweep inside one pilot allocation."
@without_setup
@with_pilot
@with_optional "group:string" "grid" "Sweep group to drain."
_sweep_pilot_job() {
    local group nodes
    group="$(knit_get_parameter group "$@")"
    nodes="$(knit_job_hostnames | wc -l)"
    knit job reconcile --group "${group}"
    knit job reset     --group "${group}"
    knit submit drain  --group "${group}" --max-inflight "${nodes}"
}
@done

# --- Job: tune-pilot --------------------------------------------------------
# Runs an ax campaign inside one allocation; resuming is resubmitting at the
# same campaign.
@job "tune-pilot" "Optimize an ax campaign inside one pilot allocation."
@without_setup
@with_pilot
@with_optional "campaign:string" "tune" "Name of a prepared ax campaign to optimize."
@with_optional "max-inflight:integer" "4" "Trials to keep in flight on the pilot's nodes."
_tune_pilot_job() {
    knit ax optimize \
        --campaign     "$(knit_get_parameter campaign "$@")" \
        --max-inflight "$(knit_get_parameter max-inflight "$@")"
}
@done

knit "$@"
