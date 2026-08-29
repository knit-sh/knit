#!/bin/bash

## @file shorthand.sh

# ------------------------------------------------------------------------------
# The "@" shorthand layer. This file defines a terse, decorator-style twin for
# every declaration/decoration function in the public API: "knit_x" gains an
# "@x" twin (with the register family remapped: knit_register -> @command,
# knit_register_<x> -> @<x>). The shorthand is additive — the knit_* functions
# are unchanged and remain the canonical, stable API — and it is enabled by
# default. A user opts out by setting KNIT_WITHOUT_SHORTHAND before sourcing
# knit (a comma-separated list of tokens, or "all").
#
# The curated set of shorthands lives in the two maps below. It cannot be
# derived mechanically from the knit_* prefix, because that prefix also covers
# runtime helpers (knit_get_parameter, the loggers, ...) which get no shorthand.
#
# Pass-through shorthands forward their arguments verbatim to the target
# (@x() { knit_x "$@"; }). The extracting shorthands (the register family) are
# wired up in a later step: they discover the decorated function's name from the
# source rather than taking it as an argument.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @var _KNIT_SHORTHAND_PASSTHROUGH
#
# Curated map from a pass-through shorthand token (the part after "@") to the
# knit_* function it forwards to verbatim. These take no function-name argument
# and are not name-extracting: the generated wrapper simply forwards "$@".
# ------------------------------------------------------------------------------
declare -gA _KNIT_SHORTHAND_PASSTHROUGH
_KNIT_SHORTHAND_PASSTHROUGH=(
    [done]=knit_done
    [empty]=knit_empty
    [resource]=knit_register_resource
    [set_program_description]=knit_set_program_description
    [define_enum]=knit_define_enum
    [define_parameter_set]=knit_define_parameter_set
    [with_required]=knit_with_required
    [with_optional]=knit_with_optional
    [with_flag]=knit_with_flag
    [with_extra]=knit_with_extra
    [with_output]=knit_with_output
    [with_artifact]=knit_with_artifact
    [with_table]=knit_with_table
    [with_checksum]=knit_with_checksum
    [with_dispatch]=knit_with_dispatch
    [with_git]=knit_with_git
    [with_local]=knit_with_local
    [with_url]=knit_with_url
    [with_parameter_set]=knit_with_parameter_set
    [with_provenance]=knit_with_provenance
    [without_provenance]=knit_without_provenance
    [with_resource]=knit_with_resource
    [with_setup]=knit_with_setup
    [without_setup]=knit_without_setup
    [with_spack_env]=knit_with_spack_env
    [with_spack_specs]=knit_with_spack_specs
    [with_subcommand_title]=knit_with_subcommand_title
    [hidden]=knit_hidden
    [hidden_if]=knit_hidden_if
    [hidden_if_not_usable]=knit_hidden_if_not_usable
    [highlight_if]=knit_highlight_if
    [usable_if]=knit_usable_if
    [usable_before_bootstrap]=knit_usable_before_bootstrap
    [no_record_on_failure]=knit_no_record_on_failure
    [provides_launcher]=knit_provides_launcher
)

# ------------------------------------------------------------------------------
# @var _KNIT_SHORTHAND_EXTRACTOR
#
# Curated map from a name-extracting shorthand token to the knit_register*
# function it forwards to. These discover the decorated function's name from the
# source and inject it at argument position 2. The wrappers are generated in a
# later step; the map is declared here so opt-out validation already recognises
# these tokens as real shorthands.
# ------------------------------------------------------------------------------
declare -gA _KNIT_SHORTHAND_EXTRACTOR
_KNIT_SHORTHAND_EXTRACTOR=(
    [command]=knit_register
    [app]=knit_register_app
    [job]=knit_register_job
    [setup]=knit_register_setup
    [wrapper]=knit_register_wrapper
)

# ------------------------------------------------------------------------------
# @fn _knit_shorthand_generate()
#
# Define the "@" shorthand functions, honouring KNIT_WITHOUT_SHORTHAND. Runs
# once when knit.sh is sourced. For each non-opted-out pass-through token it
# defines "@<token>() { <target> "$@"; }". Any KNIT_WITHOUT_SHORTHAND token that
# is not a real shorthand produces a warning and is otherwise ignored; the
# special value "all" suppresses every shorthand.
# ------------------------------------------------------------------------------
_knit_shorthand_generate() {
    local without="${KNIT_WITHOUT_SHORTHAND:-}"

    # Parse KNIT_WITHOUT_SHORTHAND into an opt-out lookup. "all" is recorded
    # separately so it can short-circuit the whole generation.
    local -A opted_out=()
    local all=false
    local -a raw_tokens=()
    IFS=',' read -ra raw_tokens <<< "${without}"
    local token
    for token in "${raw_tokens[@]}"; do
        # Trim surrounding whitespace so "job, app" is accepted like "job,app".
        token="${token#"${token%%[![:space:]]*}"}"
        token="${token%"${token##*[![:space:]]}"}"
        [[ -z "${token}" ]] && continue
        if [[ "${token}" == "all" ]]; then
            all=true
            continue
        fi
        opted_out["${token}"]=1
    done

    # Warn about opt-out tokens that name no real shorthand (typically a typo).
    for token in "${!opted_out[@]}"; do
        if [[ -z "${_KNIT_SHORTHAND_PASSTHROUGH[${token}]:-}" ]] \
            && [[ -z "${_KNIT_SHORTHAND_EXTRACTOR[${token}]:-}" ]]; then
            knit_warning \
                "KNIT_WITHOUT_SHORTHAND: unknown shorthand token '%s'; ignoring" \
                "${token}"
        fi
    done

    [[ "${all}" == true ]] && return 0

    # Generate the pass-through shorthands. eval is unavoidable here: bash has no
    # way to bind a dynamically-computed name to a function body other than
    # eval. The token and target both come from the fixed curated map above and
    # never from user input, so the generated text is fully controlled.
    local target
    for token in "${!_KNIT_SHORTHAND_PASSTHROUGH[@]}"; do
        [[ -n "${opted_out[${token}]:-}" ]] && continue
        target="${_KNIT_SHORTHAND_PASSTHROUGH[${token}]}"
        eval "@${token}() { ${target} \"\$@\"; }"
    done
}

_knit_shorthand_generate
