#!/bin/bash

## @file sweep.sh
## Exhaustive cartesian-product proposer: `knit sweep` runs a command, job, or
## app once per point in the cartesian product of a set of values per parameter.
## It is built on top of the shared search engine (see search.sh): it scans the
## downstream command for sweep-syntax tokens, enumerates the product with a
## simple odometer, and re-emits the reconstructed command line per combination.
## The sweep is opaque to the downstream command — it never parses the
## submit/run option surface or the target's parameters, except at the single
## introspection point used to resolve declared domains.

# ------------------------------------------------------------------------------
# @var _KNIT_SWEEPS_TABLE
#
# Name of the table recording every sweep campaign. The row id is the sweep's own
# UUID. Each child point (a submitted/run/command invocation, or a prepared row)
# records an automatic "call" edge back to this row through the provenance graph,
# so a campaign's children are found by walking the edges, not by a stored column.
# The column set is fixed and kind-independent: id, the recorded "group" label,
# and the "target"/"dispatcher"/"dimensions"/"count" outputs. The control options
# (--on-failure/--parallel/--passthrough/--fill/--dry-run) are declared with
# "--no-record" so they are parsed and validated but add no column.
# ------------------------------------------------------------------------------
declare -g _KNIT_SWEEPS_TABLE
_KNIT_SWEEPS_TABLE="sweeps"

# Enumerated values for the two policy options, so the CLI validates a bad value
# with the standard "expects one of: ..." message instead of the sweep having to
# check by hand.
knit_enum "sweep_on_failure" "continue" "stop"
knit_enum "sweep_fill" "default" "sweep"

knit_register "sweep" _knit_sweep \
    "Run a command, job, or app once per point in a cartesian product of values."
_knit_is_builtin
# The campaign label is the one recorded option: it becomes the "group" column
# and is forwarded into a submit/prepare line so the children land in the same
# jobs.group (see _knit_search_group_forward, extended in a later milestone).
knit_with_optional "group:string" "" \
    "Campaign label; recorded and forwarded into a submit/prepare line."
# Control options. Each is parsed, type-validated, and shown in "--help", but
# marked "--no-record" so it never widens the fixed "sweeps" column set.
knit_with_optional "on-failure:sweep_on_failure" "continue" \
    "Abort on the first failed child (stop), or keep going (continue). Ephemeral modes only." \
    --no-record
knit_with_optional "parallel:integer" "1" \
    "Ephemeral modes only: keep at most this many children in flight at once." \
    --no-record
knit_with_optional "passthrough:string" "" \
    "Comma-separated option names whose values are never treated as sweep-syntax." \
    --no-record
knit_with_optional "fill:sweep_fill" "default" \
    "Policy for an unspecified parameter: keep its default, or sweep its declared domain." \
    --no-record
knit_with_flag "dry-run" \
    "Print each reconstructed command line and exit without recording or running." \
    --no-record
knit_with_dispatch "downstream" \
    "A knit command (submit/prepare/run, or a command) with sweep-syntax values."
knit_with_table "${_KNIT_SWEEPS_TABLE}"
knit_with_output "target:string" "" \
    "The downstream target: the job, app, or command name."
knit_with_output "dispatcher:string" "" \
    "The downstream dispatcher: submit, prepare, run, or the command itself."
knit_with_output "dimensions:string" "" \
    "JSON object of the swept axes and their value lists."
knit_with_output "count:integer" "0" \
    "Number of points in the cartesian product."

# ------------------------------------------------------------------------------
# @fn _knit_sweep_downstream()
#
# Split a sweep invocation's arguments at the first "--" and return, by nameref,
# the downstream token list: everything after that first "--". The downstream is
# the real knit command the sweep wraps (e.g. "submit ... -- <job> ..." or a bare
# "<command> ..."); any inner "--" it carries (a submit/prepare/run line has one)
# is preserved, because only the first "--" separates the sweep's own options
# from the downstream.
#
# @param[out] __knit_ret Name of the array to receive the downstream tokens.
# @param[in] ... The sweep invocation arguments.
# ------------------------------------------------------------------------------
_knit_sweep_downstream() {
    local -n __knit_ret=$1; shift
    local args=("$@")
    local idx
    idx=$(knit_extra_index "${args[@]}")
    __knit_ret=("${args[@]:idx}")
}

# ------------------------------------------------------------------------------
# @fn _knit_sweep()
#
# Entry point for the `sweep` CLI command. The sweep's own options are parsed and
# validated by the framework before the body runs (the control options are
# declared with "--no-record" so they validate but add no table column). This
# body splits the downstream off the first "--" and validates that a downstream
# command is present.
#
# The scan (M2), declared-domain resolution (M3), odometer and line
# reconstruction (M4), and execution (M5) are added in later milestones; for now
# the body stops after the split so the command registers, parses, and records a
# campaign row with the fixed column set.
#
# Usage:
# ```
# ./exp.sh sweep [SWEEP ARGS] -- <downstream knit command, with sweep-syntax values>
# ```
# ------------------------------------------------------------------------------
_knit_sweep() {
    local args=("$@")
    local -a downstream
    _knit_sweep_downstream downstream "${args[@]}"
    if [[ ${#downstream[@]} -eq 0 ]]; then
        knit_fatal "sweep requires a downstream command after -- (e.g. \"-- submit -- <job>\", \"-- run -- <app>\", or \"-- <command>\")."
    fi
}
knit_done
