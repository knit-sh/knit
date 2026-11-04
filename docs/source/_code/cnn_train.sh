#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- PART III, Steps 1-2: the first training run and its
# search space. A uv-backed setup installs the cifar-cnn classifier, a `cifar`
# resource downloads the dataset, and a `train` job trains one architecture and
# records its validation accuracy. Each tunable parameter also declares a --domain,
# the search space the rest of the part explores.
#
# Source-only: building the setup needs uv and network access, and training
# needs the dataset and real compute, none of which run in plain CI, so
# check-docs only syntax-checks this file. Behavior was validated live during
# development.

source knit.sh

# uv ships as a plugin: it adds the uv environment manager the setup below uses
# (@with_uv_specs) and the knit-private uv that `bootstrap` provisions. The short
# form expands to github.com/knit-sh/knit-uv.
knit_import uv

knit_set_program_description "Tune a CNN image classifier on CIFAR-10."

# START setup
# A uv-backed setup installs the classifier. @with_uv_specs declares a uv Python
# environment whose single requirement is the cifar-cnn package, installed
# straight from its git repository; knit builds and activates it as the setup's
# first step, so the `cifar-cnn` console script is on PATH before any job that
# declares this setup runs. It captures the resolved pyproject.toml / uv.lock as
# provenance. The setup needs no body of its own --- building the environment is
# all it does --- so @empty stands in for the body function.
@setup "cnnenv" "A uv environment with the cifar-cnn classifier installed."
@with_uv_specs "cifar-cnn @ git+https://github.com/knit-sh/image-classifier-example.git"
@empty
@done
# END setup

# START resource
# A resource declares HOW to acquire an input. @with_url makes `cifar` a
# downloadable resource whose default URL is the CIFAR-10 python archive;
# `knit fetch --name cifar -- cifar --uncompress` downloads and unpacks it into
# resources/cifar/ once, then records the URL for provenance. The train job
# reads the staged directory back through knit_resource_path.
@resource "cifar" "The CIFAR-10 dataset, downloaded and unpacked."
@with_url "https://www.cs.toronto.edu/~kriz/cifar-10-python.tar.gz"
@done
# END resource

# START job
# The job that trains one network and records its validation accuracy. It
# declares the cnnenv setup (so cifar-cnn is on PATH) and the cifar resource (so
# the dataset is staged). Its body runs `cifar-cnn train`, reads the
# machine-readable "RESULT val_accuracy=..." line the program prints, and records
# it with knit_output --- that recorded column is the objective later steps rank
# and optimize.
#
# Each tunable parameter also carries a --domain: its search space, a range
# [lo..hi] or a set {a,b,c}. The job runs fine without mentioning domains (every
# parameter has a default); the domains come into play in Step 2, when we search.
# There is deliberately no @with_table here: @job already declares the job's own
# table, which is where the objective is read; a bare @with_table would split
# recording from that table.
@job "train" "Train the CNN and record its validation accuracy."
@with_setup    "cnnenv"
@with_resource "data:cifar" "Name of the fetched CIFAR instance."
@with_optional "dataset:string"        "cifar10" "Dataset loader (not searched)."
@with_optional "num-blocks:integer"    "3"       "Convolution blocks."          --domain '[1..5]'
@with_optional "base-channels:integer" "32"      "Channels in the first block." --domain '{16,32,64}'
@with_optional "kernel-size:integer"   "3"       "Convolution kernel size."     --domain '{3,5}'
@with_optional "epochs:integer"        "3"       "Training epochs (not searched)."
@with_output   "val_accuracy:real"     "0"       "Final-epoch validation accuracy (%)."
_train_job() {
    local datadir dataset out acc
    datadir="$(knit_resource_path "$(knit_get_parameter data "$@")")"
    dataset="$(knit_get_parameter dataset "$@")"

    out="$(cifar-cnn train \
        --model         "${KNIT_JOB_PREFIX%/}/model.pt" \
        --dataset       "${dataset}" \
        --data          "${datadir}" \
        --num-blocks    "$(knit_get_parameter num-blocks "$@")" \
        --base-channels "$(knit_get_parameter base-channels "$@")" \
        --kernel-size   "$(knit_get_parameter kernel-size "$@")" \
        --epochs        "$(knit_get_parameter epochs "$@")" \
        2>&1 | tee /dev/stderr)"

    acc="$(grep -oE 'RESULT val_accuracy=[0-9.]+' <<<"${out}" | tail -1 | cut -d= -f2)"
    knit_output "val_accuracy" "${acc:-0}"
}
@done
# END job

knit "$@"
