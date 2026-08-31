#!/bin/bash

# Showcase for the "Answer with a generated query" stitch recipe: a tiny
# experiment that records a table, so `ai query` has real columns to write SQL
# against and a real command to reference in a Cypher relationship question.
# Kept to the local backend so the driver can bootstrap and record a row on any
# CI runner (the `ai query` calls themselves need a live provider, so the driver
# only checks that the command is wired up, not that it answers).

# START run
source knit.sh

knit_set_program_description "A tiny experiment for querying with ai query."
# END run

# START montecarlo
@command "montecarlo" "Estimate pi and record the run."
@with_required "samples:integer" "How many samples to draw."
@with_optional "seed:integer" "1" "Random seed."
@with_output "pi:real" "0" "The estimate produced by this run."
@with_table
montecarlo() {
    local samples seed estimate
    samples="$(knit_get_parameter "samples" "$@")"
    seed="$(knit_get_parameter "seed" "$@")"
    # A deterministic stand-in for a real estimate: enough to populate the
    # `montecarlo` table (samples, seed, pi) that `ai query` writes SQL against.
    # seed 1 gives exactly 3.14159; other seeds nudge it so runs differ.
    estimate="$(awk -v d="${seed}" \
        'BEGIN { printf "%.5f", 3.14159 + (d - 1) / 100000 }')"
    knit_output "pi" "${estimate}"
    printf 'samples=%s pi=%s\n' "${samples}" "${estimate}"
}
@done
# END montecarlo

knit "$@"
