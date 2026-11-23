#!/bin/bash

# doc-check: source-only
#
# Showcase for the "Provide a setup role" recipe: two differently-built setups
# that both advertise one role, and a single job that accepts any instance of
# that role. A job normally pins one exact setup type; a role lets several
# interchangeable setups satisfy the same requirement --- e.g. one "train" job
# that runs under a CUDA environment on one machine and a CPU environment on
# another.
#
# Source-only: materializing the environments and submitting the job need a
# provisioned toolchain and a scheduler, neither of which runs in plain CI, so
# check-docs only syntax-checks this file.

source knit.sh

# START roles
# Two setups built in different ways --- here distinguished only by the marker
# each records --- that both provide the "cnnenv" role. @provides_setup_role may
# be repeated to provide several roles.
@setup "cnnenv-cuda" "cifar-cnn with a CUDA PyTorch."
@provides_setup_role "cnnenv"
_cnnenv_cuda() { knit_setup_env_set CNN_DEVICE cuda; }
@done

@setup "cnnenv-cpu" "cifar-cnn with a CPU PyTorch."
@provides_setup_role "cnnenv"
_cnnenv_cpu() { knit_setup_env_set CNN_DEVICE cpu; }
@done

# The job requires the ROLE, not a type: any instance providing "cnnenv" is
# accepted, so the same job runs under either environment above. Build the one
# that fits each machine (knit setup --name cuda -- cnnenv-cuda) and submit the
# same job against it (knit submit --setup cuda -- train).
@job "train" "Train the model in whichever cnnenv is provided."
@with_setup "cnnenv"
_train() { echo "training on ${CNN_DEVICE}"; }
@done
# END roles

knit "$@"
