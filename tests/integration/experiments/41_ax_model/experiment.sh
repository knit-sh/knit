#!/usr/bin/env bash
# Integration test experiment 41_ax_model.
#
# Drives the knit-ax plugin's surrogate-model (active-learning) mode against the
# real cluster scheduler. Unlike 40_ax_optimize (which chases an optimum), this
# campaign fits a surrogate of the objective with "ax prepare --model", then
# queries it with "ax predict" and checks its fit with "ax show --diagnostics".
#
# The search space is mixed on purpose: one continuous range axis (--x over
# [0..12]) and one discrete choice axis (--k over {1,2,3,4}), so the model-mode
# path is exercised over both axis kinds at once. The objective is a closed-form
# surrogate so trials are fast anywhere: score = 100 - (x-6)^2 - (k-2)^2.
#
# The plugin is pinned to the released tag (which ships the --model / ax predict
# / ax show --diagnostics surface); the resolved commit freezes in
# knit-plugins.lock on first import.

source knit.sh

knit_import ax@v1.0.0

knit_set_program_description "knit-ax surrogate-model (active-learning) integration test."

knit_register_job "surf" __surf_job_fn "Evaluate a 2-D closed-form surrogate (range + choice)."
knit_without_setup
knit_with_optional "x:real"    "0" "Continuous knob over [0..12]." --domain '[0..12]'
knit_with_optional "k:integer" "1" "Discrete knob, varied over a {...} choice set."
knit_with_output   "score:real" "0" "Surrogate score = 100 - (x-6)^2 - (k-2)^2."
__surf_job_fn() {
    local x k score
    x=$(knit_get_parameter "x" "$@")
    k=$(knit_get_parameter "k" "$@")
    score=$(awk -v x="${x}" -v k="${k}" \
        'BEGIN { printf "%.6f", 100 - (x - 6) * (x - 6) - (k - 2) * (k - 2) }')
    knit_output "score" "${score}"
    printf 'surf: x=%s k=%s score=%s\n' "${x}" "${k}" "${score}"
}
knit_done

knit "$@"
