#!/bin/bash

# Showcase for `knit sweep`: run a job once per point in the cartesian product of
# a set of values per parameter. Kept to the local backend so check-docs drives
# both the ephemeral `-- submit` loop and the durable `-- prepare` + drain queue
# end to end (see sweep.check.sh).

source knit.sh

knit_set_program_description "Sweep a job over a product of parameter values."

# START job
# An ordinary job whose tunable parameter carries a search --domain, so the sweep
# can draw its values from the declaration (--fill sweep / --n @sweep) as well as
# from an explicit set on the command line (--n '{1,2,4}').
@job "sim" "Run one trivial simulation."
@without_setup
@with_optional "n:integer"      "1" "Number of steps." --domain '{1,2,4}'
@with_table
@with_output   "result:integer" "0" "Twice the step count (a stand-in result)."
_sim() {
    local n
    n=$(knit_get_parameter "n" "$@")
    knit_output "result" "$(( n * 2 ))"
    printf 'sim: n=%s result=%s\n' "${n}" "$(( n * 2 ))"
}
@done
# END job

knit "$@"
