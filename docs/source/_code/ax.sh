#!/bin/bash

# doc-check: source-only
#
# Showcase for the "Optimize a job with Bayesian search" recipe: a job whose
# declared numeric output the knit-ax plugin tunes with an ask/tell loop over a
# declared search domain.
#
# Source-only: running "ax optimize" builds a real Ax environment (uv +
# ax-platform) and drives a coprocess, none of which run in plain CI, so
# check-docs only syntax-checks this file. The job registration below is still
# exercised by the describe drift guard, the same as every other example.

source knit.sh

# knit-ax is a plugin; import it (it imports knit-uv in turn) before using the
# "ax" commands. The short form expands to github.com/knit-sh/knit-ax.
knit_import ax

knit_set_program_description "Optimize a surrogate job with Bayesian search."

# START job
# An ordinary job with one tunable real knob carrying a search --domain and a
# declared numeric output. Each trial, "ax optimize" proposes an x within the
# domain, runs the job, reads the recorded output, and feeds it back to the
# model. The objective is closed-form here so the example is self-contained; a
# real job would run a simulation and record its figure of merit.
@job "quad" "Evaluate the surrogate objective."
@without_setup
@with_optional "x:real"     "0" "The knob to optimize." --domain '[0..12]'
# @job already declares the job's table (named "quad"); do not add @with_table,
# which would re-point it at the "submit:quad" command name and split recording
# from where the objective is read.
@with_output   "score:real" "0" "Objective = 100 - (x - 6)^2 (max 100 at x = 6)."
_quad() {
    local x score
    x=$(knit_get_parameter "x" "$@")
    score=$(awk -v x="${x}" 'BEGIN { printf "%.6f", 100 - (x - 6) * (x - 6) }')
    knit_output "score" "${score}"
    printf 'quad: x=%s score=%s\n' "${x}" "${score}"
}
@done
# END job

knit "$@"
