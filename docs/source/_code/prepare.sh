#!/bin/bash

# Showcase for the "prepare" recipes: deferred submission. `prepare` builds and
# records a job exactly as `submit` does, but stops before the scheduler, leaving
# a "prepared" row you release later with `submit next` / `submit prepared`.
#
# This example is runnable: preparing never contacts a scheduler, and releasing a
# job dispatches it to the portable local backend, so check-docs drives the whole
# prepare -> release -> complete lifecycle end to end (see prepare.check.sh).

source knit.sh

knit_set_program_description "Prepare jobs now and release them later."

# START job
# A job you prepare now and release later. Nothing about it is special: `prepare`
# and `submit` share one job registry, so any job you can submit you can prepare.
@job "sim" "Run one simulation."
@without_setup
@with_optional "n:integer"      "10"   "Number of steps to run."
@with_optional "label:string"   "run"  "A label recorded with the run."
@with_table
@with_output   "result:integer" "0"    "Twice the step count (a stand-in result)."
_sim() {
    local n label
    n=$(knit_get_parameter "n" "$@")
    label=$(knit_get_parameter "label" "$@")
    knit_output "result" "$(( n * 2 ))"
    printf '%s: result=%s\n' "${label}" "$(( n * 2 ))"
}
@done
# END job

# The example plan for `prepare from`, printed by the `plan` command. The recipe
# renders the JSON body directly (its literalinclude anchors on the here-doc
# delimiters), so this is the exact plan the docs show and the driver runs.
@command "plan" "Print the example sweep plan as JSON."
_sweep_plan() {
    cat <<'JSON'
{
  "group": "sweep",
  "jobs": [
    { "job": "sim", "args": { "n": 5, "label": "baseline" } },

    { "matrix": {
        "job": "sim",
        "axes": {
          "args":  [ {"label": "a"}, {"label": "b"} ],
          "nodes": [ 1, 2 ]
        },
        "exclude": [ { "args": {"label": "b"}, "nodes": 2 } ],
        "include": [ { "args": {"label": "c"}, "nodes": 4 } ]
    } }
  ]
}
JSON
}
@done

knit "$@"
