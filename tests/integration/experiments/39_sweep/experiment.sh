#!/usr/bin/env bash
# Integration test experiment 39_sweep.
#
# A single self-contained job (no setup) used to exercise `knit sweep` against
# the real cluster scheduler: "sim" only does arithmetic and records a result,
# so it runs fast anywhere. Its --n parameter carries a search --domain so the
# sweep can draw values from the declaration (--fill sweep / @sweep) as well as
# from an explicit set on the command line.

source knit.sh

knit_set_program_description "knit sweep integration test experiment."

knit_register_job "sim" __sim_job_fn "Run one trivial simulation."
knit_without_setup
knit_with_optional "n:integer"      "1"  "Number of steps to run." --domain '{1,2,4}'
knit_with_table
knit_with_output   "result:integer" "0"  "Twice the step count (a stand-in result)."
__sim_job_fn() {
    local n
    n=$(knit_get_parameter "n" "$@")
    knit_output "result" "$(( n * 2 ))"
    printf 'sim: n=%s result=%s\n' "${n}" "$(( n * 2 ))"
}
knit_done

knit "$@"
