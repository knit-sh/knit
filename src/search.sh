#!/bin/bash

## @file search.sh

# ------------------------------------------------------------------------------
# The search-core descriptor layer: the one grammar and parser for a searchable
# parameter's value domain, shared by the declared "--domain" flag and the
# sweep's call-site tokens. A descriptor has a kind (list, range, or glob) and
# the payload of that kind:
#
#   {a,b,c}          -> kind=list,  values=(a b c)
#   [lo..hi]         -> kind=range, lo hi          (step empty; integers imply 1)
#   [lo..hi:step]    -> kind=range, lo hi step
#   @glob:<pattern>  -> kind=glob,  glob=<pattern> (expanded later, at use time)
#   @file:<path>     -> kind=list,  values=(one value per line of <path>)
#
# This file owns only the descriptor: it parses one token into the structured
# form, and it validates that form against a parameter's declared type (the
# type x kind rules). Storing a declared descriptor, reading it back, and
# enumerating or sampling it are later layers.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_search_parse_literal()
#
# Parse one domain descriptor token into its structured form. The same grammar
# is used for a declared "--domain" value and for a sweep call-site token, so
# this is the single parser for both. The caller MUST declare the first output
# as an associative array (declare -A) and the second as an ordinary array.
#
# Keys that do not apply to the parsed kind are set to the empty string. A
# "@glob:" pattern is stored verbatim (its expansion to a list happens later, at
# use time); a "@file:" path is read now, one value per line. A malformed or
# unrecognised token is fatal.
#
# Example:
# ```
# local -A desc; local values
# _knit_search_parse_literal desc values '[1..10:2]'   # desc[kind]=range, lo=1, hi=10, step=2
# _knit_search_parse_literal desc values '{a,b,c}'     # desc[kind]=list, values=(a b c)
# ```
#
# @param[out] __knit_ret1 Associative array to receive the descriptor scalars:
#   keys kind (list|range|glob), lo, hi, step, glob.
# @param[out] __knit_ret2 Indexed array to receive the list values (empty unless
#   kind=list).
# @param[in] token The descriptor token to parse.
# ------------------------------------------------------------------------------
_knit_search_parse_literal() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local token="$3"

    # shellcheck disable=SC2034 # keys are read through the caller's nameref
    __knit_ret1=( [kind]="" [lo]="" [hi]="" [step]="" [glob]="" )
    __knit_ret2=()

    if [[ "${token}" == '{'*'}' ]]; then
        local body="${token:1:${#token}-2}"
        if [[ -z "${body}" ]]; then
            knit_fatal "Empty list domain '%s'." "${token}"
        fi
        local IFS=','
        # shellcheck disable=SC2206 # deliberate comma split into the values array
        __knit_ret2=( ${body} )
        __knit_ret1[kind]="list"
        return 0
    fi

    if [[ "${token}" == '['*']' ]]; then
        local body="${token:1:${#token}-2}"
        local step=""
        if [[ "${body}" == *:* ]]; then
            step="${body#*:}"
            body="${body%%:*}"
            if [[ "${step}" == *:* ]]; then
                knit_fatal "Malformed range domain '%s' (expected [lo..hi] or [lo..hi:step])." "${token}"
            fi
        fi
        local lo="${body%%..*}"
        local hi="${body#*..}"
        if [[ "${body}" != *..* || -z "${lo}" || -z "${hi}" || "${hi}" == *..* ]]; then
            knit_fatal "Malformed range domain '%s' (expected [lo..hi] or [lo..hi:step])." "${token}"
        fi
        __knit_ret1[kind]="range"
        __knit_ret1[lo]="${lo}"
        __knit_ret1[hi]="${hi}"
        __knit_ret1[step]="${step}"
        return 0
    fi

    if [[ "${token}" == '@glob:'* ]]; then
        __knit_ret1[kind]="glob"
        __knit_ret1[glob]="${token#@glob:}"
        return 0
    fi

    if [[ "${token}" == '@file:'* ]]; then
        local path="${token#@file:}"
        if [[ ! -r "${path}" ]]; then
            knit_fatal "Cannot read @file domain '%s'." "${path}"
        fi
        local line
        while IFS= read -r line || [[ -n "${line}" ]]; do
            __knit_ret2+=("${line}")
        done < "${path}"
        __knit_ret1[kind]="list"
        return 0
    fi

    knit_fatal "'%s' is not a domain descriptor ({...}, [lo..hi], @glob:..., or @file:...)." "${token}"
}

# ------------------------------------------------------------------------------
# @fn _knit_search_validate_descriptor()
#
# Validate a parsed descriptor against a parameter's declared type, applying the
# type x kind rules. Fatals on any violation (the same hard-stop behaviour as
# the other declaration-time checks):
#
#   - a range needs an integer or real parameter; each bound and the step must
#     be a valid value of that type;
#   - a glob needs a string parameter;
#   - a list is allowed for any type, and every value must be valid for it (an
#     enum list thus restricts the enum to the named subset; a boolean list must
#     be true/false);
#   - the --log scale hint applies only to a real range.
#
# @param[in] __knit_desc Name of the associative array holding the descriptor
#   scalars (as produced by _knit_search_parse_literal).
# @param[in] __knit_values Name of the indexed array holding the list values.
# @param[in] type The parameter's declared type (name or alias).
# @param[in] log Whether the --log scale hint was given ("true" to enable).
# @return 0 if the descriptor is valid (otherwise fatal).
# ------------------------------------------------------------------------------
_knit_search_validate_descriptor() {
    local -n __knit_desc=$1
    local -n __knit_values=$2
    local type="$3"
    local log="${4:-}"

    local resolved
    if ! _knit_type_resolve_alias resolved "${type}"; then
        knit_fatal "Unknown parameter type '%s' for a search domain." "${type}"
    fi

    local kind="${__knit_desc[kind]}"
    case "${kind}" in
        range)
            if [[ "${resolved}" != "integer" && "${resolved}" != "real" ]]; then
                knit_fatal "A range domain requires an integer or real parameter (got '%s')." "${type}"
            fi
            local bound
            for bound in "${__knit_desc[lo]}" "${__knit_desc[hi]}"; do
                if ! knit_type_check "${resolved}" "${bound}"; then
                    knit_fatal "Range bound '%s' is not a valid %s." "${bound}" "${resolved}"
                fi
            done
            if [[ -n "${__knit_desc[step]}" ]] \
                && ! knit_type_check "${resolved}" "${__knit_desc[step]}"; then
                knit_fatal "Range step '%s' is not a valid %s." "${__knit_desc[step]}" "${resolved}"
            fi
            ;;
        glob)
            if [[ "${resolved}" != "string" ]]; then
                knit_fatal "A glob domain requires a string parameter (got '%s')." "${type}"
            fi
            ;;
        list)
            if [[ "${#__knit_values[@]}" -eq 0 ]]; then
                knit_fatal "A list domain has no values."
            fi
            local value
            for value in "${__knit_values[@]}"; do
                if ! knit_type_check "${resolved}" "${value}"; then
                    knit_fatal "Domain value '%s' is not a valid %s." "${value}" "${type}"
                fi
            done
            ;;
        *)
            knit_fatal "Descriptor has no kind."
            ;;
    esac

    if [[ "${log}" == "true" && ( "${kind}" != "range" || "${resolved}" != "real" ) ]]; then
        knit_fatal "The --log scale hint applies only to a real range domain."
    fi
}
