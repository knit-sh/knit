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
    [artifact]=knit_register_artifact
    [enum]=knit_enum
    [parameter_set]=knit_parameter_set
    [with_required]=knit_with_required
    [with_optional]=knit_with_optional
    [with_flag]=knit_with_flag
    [with_extra]=knit_with_extra
    [with_output]=knit_with_output
    [with_output_artifact]=knit_with_output_artifact
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
# @fn _knit_shorthand_find_function()
#
# Discover the name a name-extracting registration shorthand (@command, @job,
# @app, @setup, @wrapper) decorates. The shorthand captures its own call site and
# passes it here; the name is read from the source rather than taken as an
# argument.
#
# The source file is read and the lines after "line" are scanned. Blank lines,
# comments, and intervening decorator lines (@with_*, @usable_if, ...) are
# skipped. The scan stops at the first of:
#   - an "@empty" marker line   -> the discovered body name is "knit_empty";
#   - a function definition      -> its name is returned. All common styles are
#     recognised: "name() {", "name () ...", "function name ...", one-liners, and
#     names containing "@" (bash allows them).
#
# The discovery is textual, so the function need not be defined yet when the
# shorthand runs.
#
# @param[out] The name of the variable that receives the discovered name.
# @param[in] file The source file to read (BASH_SOURCE of the call site).
# @param[in] line The 1-based line number of the shorthand call (BASH_LINENO).
#
# Fatal when the source is not a readable file (piped/eval'd script), and when
# neither a function definition nor an "@empty" marker is found before the next
# "@done"/"knit_done" or the end of the file.
# ------------------------------------------------------------------------------
_knit_shorthand_find_function() {
    local -n __knit_ret=$1
    local file="$2"
    local line="$3"

    # The call site must be a readable regular file. It is not when the
    # experiment was piped ("curl ... | bash"), read from a process
    # substitution, or eval'd, so BASH_SOURCE points at no on-disk source.
    if [[ ! -f "${file}" || ! -r "${file}" ]]; then
        knit_fatal \
            "shorthand: cannot read the source '%s' to discover the decorated function; use the long knit_register* form with an explicit function name" \
            "${file}"
    fi

    local -a lines=()
    mapfile -t lines < "${file}"
    local total="${#lines[@]}"

    # Line N (1-based) is at array index N-1, so the lines after the call start
    # at array index "line".
    local i text name
    for (( i = line; i < total; i++ )); do
        text="${lines[i]}"

        # The @empty marker: the decorated command has no body function.
        if [[ "${text}" =~ ^[[:space:]]*@empty([[:space:]]|$) ]]; then
            __knit_ret="knit_empty"
            return 0
        fi

        # "function name" style, with or without a following "()".
        if [[ "${text}" =~ ^[[:space:]]*function[[:space:]]+([^[:space:](){}]+) ]]; then
            __knit_ret="${BASH_REMATCH[1]}"
            return 0
        fi

        # "name()" / "name ()" style (name may contain "@").
        if [[ "${text}" =~ ^[[:space:]]*([^[:space:](){}]+)[[:space:]]*\(\) ]]; then
            name="${BASH_REMATCH[1]}"
            # Guard against a "@done"/"knit_done" written with parentheses being
            # mistaken for the body function.
            if [[ "${name}" != "@done" && "${name}" != "knit_done" ]]; then
                __knit_ret="${name}"
                return 0
            fi
        fi

        # The registration was closed before any function or @empty appeared.
        if [[ "${text}" =~ ^[[:space:]]*(@done|knit_done)([[:space:]]|\;|$) ]]; then
            break
        fi
    done

    knit_fatal \
        "shorthand: no function definition or @empty marker found after line %s of '%s' before the next @done or end of file" \
        "${line}" "${file}"
}

# ------------------------------------------------------------------------------
# @fn _knit_shorthand_generate()
#
# Define the "@" shorthand functions, honouring KNIT_WITHOUT_SHORTHAND. Runs
# once when knit.sh is sourced. For each non-opted-out pass-through token it
# defines "@<token>() { <target> "$@"; }"; for each non-opted-out extracting
# token it defines a wrapper that discovers the decorated function's name and
# injects it at argument position 2. Any KNIT_WITHOUT_SHORTHAND token that is not
# a real shorthand produces a warning and is otherwise ignored; the special
# value "all" suppresses every shorthand.
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

    # Generate the name-extracting registration shorthands. Each wrapper captures
    # its own call site (BASH_SOURCE[1]/BASH_LINENO[0], stable because the
    # wrapper is the direct callee of the user's line), discovers the decorated
    # function's name, and forwards it at argument position 2 — the "fn" slot all
    # five knit_register* targets share. The same eval rationale as above holds:
    # token and target come from the fixed curated map, never user input.
    for token in "${!_KNIT_SHORTHAND_EXTRACTOR[@]}"; do
        [[ -n "${opted_out[${token}]:-}" ]] && continue
        target="${_KNIT_SHORTHAND_EXTRACTOR[${token}]}"
        eval "@${token}() {
    local file=\"\${BASH_SOURCE[1]}\"
    local line=\"\${BASH_LINENO[0]}\"
    local fn
    _knit_shorthand_find_function fn \"\${file}\" \"\${line}\"
    ${target} \"\$1\" \"\${fn}\" \"\${@:2}\"
}"
    done
}

_knit_shorthand_generate
