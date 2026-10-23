#!/usr/bin/env bash
# Integration test experiment 40_ax_optimize.
#
# Drives the knit-ax Bayesian-optimization plugin against the real cluster
# scheduler. The plugin is imported live (it transitively imports knit-uv and
# registers a private uv-backed "_ax-driver" environment, so bootstrap
# auto-provisions the knit-private uv and "ax optimize" builds a real Ax at
# first use — no GPU needed).
#
# The objective is a closed-form surrogate so trials are fast anywhere: a single
# self-contained job "quad" with no setup takes one real knob --x over a search
# --domain and records score = 100 - (x - 6)^2. The maximum is x = 6 with
# score 100, a one-dimensional problem Bayesian optimization converges on in a
# handful of trials. Each trial is a genuine job submitted to the scheduler.

source knit.sh

# Import the Ax plugin (it imports knit-uv in turn). Temporarily pinned to the
# main branch until knit-ax cuts v1.0.0; the resolved commit is frozen in
# knit-plugins.lock either way. Switch this to ax@v1.0.0 at the release.
knit_import ax@main

knit_set_program_description "knit-ax Bayesian-optimization integration test experiment."

knit_register_job "quad" __quad_job_fn "Evaluate the closed-form surrogate."
knit_without_setup
knit_with_optional "x:real"         "0" "The knob to optimize." --domain '[0..12]'
knit_with_table
knit_with_output   "score:real"     "0" "Surrogate score = 100 - (x - 6)^2 (max 100 at x = 6)."
__quad_job_fn() {
    local x score
    x=$(knit_get_parameter "x" "$@")
    score=$(awk -v x="${x}" 'BEGIN { printf "%.6f", 100 - (x - 6) * (x - 6) }')
    knit_output "score" "${score}"
    printf 'quad: x=%s score=%s\n' "${x}" "${score}"
}
knit_done

knit "$@"
