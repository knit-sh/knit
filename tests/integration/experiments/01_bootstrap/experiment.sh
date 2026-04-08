#!/usr/bin/env bash
# Integration test experiment 01_bootstrap.
# A minimal knit experiment script — sources knit.sh and dispatches to knit().
# No commands are registered; this experiment only exercises bootstrap.

source /shared/knit/knit.sh

knit_set_program_description "Bootstrap integration test experiment."

knit "$@"
