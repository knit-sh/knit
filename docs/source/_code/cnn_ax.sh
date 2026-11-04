#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- PART III, Step 8: the search space grows past what a grid
# can cover, so a Bayesian optimizer (the ax plugin) proposes trials instead of
# enumerating them. The `train` job gains five more search parameters, and a
# `tune-pilot` pilot runs a whole ax campaign inside one allocation.
#
# Source-only: training needs uv, the dataset, and real compute, and "ax
# optimize" drives a real Ax environment, none of which run in plain CI, so
# check-docs only syntax-checks this file. The ax loop's convergence is validated
# live by the 40_ax_optimize integration test; behavior here was validated end to
# end during development.

source knit.sh

# uv and ax ship as plugins. Importing uv adds the uv environment manager the
# cnnenv setup uses; importing ax adds the `ax` optimizer commands (ax imports uv
# in turn).
knit_import uv
knit_import ax

knit_set_program_description "Tune a CNN image classifier with Bayesian optimization."

# The cnnenv setup and the cifar resource are unchanged from Step 1.
@setup "cnnenv" "A uv environment with the cifar-cnn classifier installed."
@with_uv_specs "cifar-cnn @ git+https://github.com/knit-sh/image-classifier-example.git"
@empty
@done

@resource "cifar" "The CIFAR-10 dataset, downloaded and unpacked."
@with_url "https://www.cs.toronto.edu/~kriz/cifar-10-python.tar.gz"
@done

# The train job is the one from Step 1 with five more search parameters, so the
# space is now eight-dimensional --- far past what an exhaustive grid can reach.
@job "train" "Train the CNN and record its validation accuracy."
@with_setup    "cnnenv"
@with_resource "data:cifar" "Name of the fetched CIFAR instance."
@with_optional "dataset:string"        "cifar10" "Dataset loader (not searched)."
@with_optional "num-blocks:integer"    "3"       "Convolution blocks."          --domain '[1..5]'
@with_optional "base-channels:integer" "32"      "Channels in the first block." --domain '{16,32,64}'
@with_optional "kernel-size:integer"   "3"       "Convolution kernel size."     --domain '{3,5}'
# START newparams
@with_optional "dropout:real"          "0.3"     "Dropout before the classifier head." --domain '[0.0..0.5]'
@with_optional "activation:string"     "relu"    "Activation function."                --domain '{relu,gelu,leaky-relu}'
@with_optional "residual:string"       "false"   "Residual skip connections."          --domain '{false,true}'
@with_optional "lr:real"               "0.001"   "Initial learning rate."              --domain '[0.0001..0.1]' --log
@with_optional "batch-size:integer"    "128"     "Mini-batch size."                    --domain '{32,64,128,256}'
# END newparams
@with_optional "epochs:integer"        "3"       "Training epochs (not searched)."
@with_output   "val_accuracy:real"     "0"       "Final-epoch validation accuracy (%)."
_train_job() {
    local datadir dataset residual out acc
    datadir="$(knit_resource_path "$(knit_get_parameter data "$@")")"
    dataset="$(knit_get_parameter dataset "$@")"

    # The program takes --residual as a bare flag, so turn the true/false
    # parameter into the flag's presence or absence.
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

# START pilot
# The ax equivalent of the sweep-draining pilot from Step 6. Its body runs
# `ax optimize` instead of `submit drain`: the ask -> submit -> observe loop
# submits each trial job, and inside the pilot allocation those submits pack onto
# the pilot's own nodes. The pilot trains nothing itself (@without_setup); each
# trial job carries the --setup frozen into the campaign at prepare time.
# Resuming is just resubmitting the same pilot at the same campaign: ax reads its
# persisted state and continues from the trials already done.
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
# END pilot

knit "$@"
