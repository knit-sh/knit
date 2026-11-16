#!/bin/bash

## @file claim.sh

# ------------------------------------------------------------------------------
# @var _KNIT_CLAIMS
#
# Associative array mapping registered claim names (normalized to underscores) to
# 1. It is the in-memory registry of declared claims, held at registration time
# rather than in the database, so `claim list` can show a claim that is declared
# but has never recorded a row.
# ------------------------------------------------------------------------------
declare -gA _KNIT_CLAIMS

# ------------------------------------------------------------------------------
# The "claim" group command. A claim is registered as the subcommand
# `claim:<name>` (see knit_register_claim), so the "claim" parent must exist
# before any claim is declared. It is an empty namespace command: a builtin that
# only groups its subcommands (the evaluation verbs in §6 and every user claim),
# records nothing, and emits no provenance. The claim evaluation verbs read the
# database, so they are not usable before bootstrap; the central runtime guard
# refuses them until the experiment is bootstrapped.
# ------------------------------------------------------------------------------
knit_register claim knit_empty \
    "Evaluate and list executable claims about the experiment."
_knit_is_builtin
knit_without_provenance
knit_done

# ------------------------------------------------------------------------------
# @fn knit_register_claim()
#
# Register a claim, i.e. a subcommand of the "claim" command that evaluates a
# plain-English finding about the experiment and reports a verdict through its
# return code. Mirrors knit_register_job: it registers `claim:<name>`, backs it
# with a per-claim table named after the claim itself, records the name in
# _KNIT_CLAIMS, and marks the command type "claim" so the evaluation verbs can
# find it.
#
# A claim differs from an ordinary command in two ways. First, it stores the raw
# statement template (its third argument) so the evaluation verbs can render the
# finding with the claim's parameters and outputs interpolated. Second, it is
# marked knit_without_provenance automatically: a claim observes the database and
# is not part of the campaign DAG, so it emits no provenance edges. The author
# writes neither the table nor the provenance mark.
#
# A call to this function must be followed by any knit_with_* declarations, the
# definition of <fn>, and a call to knit_done.
#
# The names "check" and "list" are reserved: "claim check" evaluates a binding
# and "claim list" lists recorded findings, so a claim registered under one of
# these would mangle to the same command name and shadow the verb. Registering
# such a claim is fatal.
#
# @param[in] name        Short name for the claim (used as the subcommand name).
# @param[in] fn          Name of the Bash function implementing the checker.
# @param[in] statement   Plain-English statement template; each "@name" token is
#                        interpolated at render time with the value of the
#                        condition parameter or output named "name".
#
# Example:
# ```
# knit_register_claim "a-beats-b" "a_beats_b" \
#     "Algo A beats algo B by @p percent on @d."
# knit_with_required "d:string"  "Dataset name."
# knit_with_output   "p:integer" "0" "Measured margin, percent."
# a_beats_b() {
#   ...
# }
# knit_done
# ```
# ------------------------------------------------------------------------------
knit_register_claim() {
    local name="$1"
    local fn="$2"
    local statement="$3"
    case "${name}" in
        check|list)
            knit_fatal "Claim name \"${name}\" is reserved (it would shadow a \"claim\" subcommand)."
            ;;
    esac
    knit_register "claim:${name}" "${fn}" "${statement}"
    # Canonical (underscore) name: used both for the per-claim table and the
    # registry key so they stay stable whether the claim is registered or
    # evaluated with hyphens or underscores (the registered spelling is kept for
    # display).
    local normalized_name
    _knit_name_normalize normalized_name "${name}"
    # Record each claim's evaluations in a table named after the claim itself (not
    # the "claim:<name>" command name), so the table reads naturally and needs no
    # SQL quoting of the colon. Recording a row is conditional on "--record" (see
    # the evaluation verb); declaring the table here only sets up its schema.
    knit_with_table "${normalized_name}"
    _KNIT_CLAIMS["${normalized_name}"]=1
    printf -v "_KNIT_CMD_${_KNIT_CURRENT_COMMAND}_type" '%s' 'claim'
    # The raw statement template, stored per claim so the evaluation verbs can
    # render the finding with the claim's parameters and outputs interpolated.
    printf -v "_KNIT_CLAIM_${_KNIT_CURRENT_COMMAND}_statement" '%s' "${statement}"
    # A claim observes the database and is not part of the campaign DAG, so it
    # records no provenance edge. The author does not write this.
    knit_without_provenance
}
