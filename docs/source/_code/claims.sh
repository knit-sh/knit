#!/bin/bash

# The Claims experiment. It records a few sample values, then states a
# plain-English finding about them as an executable claim: "the mean sample is at
# least <floor>". The claim's checker queries the recorded samples, reports the
# mean and the count as measured outputs, and returns a three-valued verdict. Kept
# to the local backend so it runs anywhere with just bash and sqlite3.

# START run
source knit.sh

knit_set_program_description "Record samples and make a claim about them."
# END run

# START sample
# A command that records one sample value, so the claim below has data to check.
@command "sample" "Record one sample value."
@with_required "x:real" "The sample value."
@with_table "samples"
_sample() {
    printf 'recorded %s\n' "$(knit_get_parameter "x" "$@")"
}
@done
# END sample

# START claim
# An executable claim: a plain-English statement plus a checker. The statement
# interpolates the condition parameter --floor and the measured outputs mean / n.
# The checker queries the recorded samples, reports the mean and the count with
# knit_output, and returns a three-valued verdict via the KNIT_CLAIM_* constants.
@claim "mean-above" \
    "The mean sample is at least @floor (mean @mean over @n samples)."
@with_optional "floor:real"  "0" "Lower bound the mean must meet."
@with_output   "mean:real" "Mean of the recorded samples."
@with_output   "n:integer" "Number of recorded samples."
_mean_above() {
    local floor n mean
    floor="$(knit_get_parameter "floor" "$@")"
    n="$(knit query sql --exec "SELECT count(*) FROM samples;")" || n=0
    # No sample recorded yet: the claim cannot be decided either way.
    if [[ "${n:-0}" -eq 0 ]]; then
        return "${KNIT_CLAIM_INSUFFICIENT}"
    fi
    mean="$(knit query sql --exec "SELECT avg(x) FROM samples;")"
    knit_output "n" "${n}"
    knit_output "mean" "${mean}"
    # Holds when the mean meets the floor, otherwise refuted.
    if awk -v m="${mean}" -v f="${floor}" 'BEGIN { exit !(m >= f) }'; then
        return "${KNIT_CLAIM_HOLDS}"
    fi
    return "${KNIT_CLAIM_REFUTED}"
}
@done
# END claim

knit "$@"
