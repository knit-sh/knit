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
# This file owns only the descriptor: a cheap shape check, parsing one token
# into the structured form, and validating that form against a parameter's
# declared type (the type x kind rules). A declared "--domain" is stored
# verbatim and only parsed and validated on demand (when a search proposer or
# "describe --space" reads it), so registration does not pay to parse every
# parameter's domain. Storing, reading back, enumerating, and sampling are later
# layers.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_search_is_descriptor()
#
# Cheap shape check: return 0 if a token has the form of a domain descriptor
# (a non-empty "{...}", "[...]", "@glob:...", or "@file:..."), 1 otherwise. This
# is the fork-free gate used at declaration time to reject a gross typo without
# a full parse; it does not check the internal well-formedness of a range or the
# type x kind rules (those are the parser's and validator's job, on demand).
#
# @param[in] token The token to check.
# @return 0 if the token looks like a descriptor, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_search_is_descriptor() {
    case "$1" in
        '{'?*'}')   return 0 ;;
        '['?*']')   return 0 ;;
        '@glob:'?*) return 0 ;;
        '@file:'?*) return 0 ;;
    esac
    return 1
}

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

# ------------------------------------------------------------------------------
# @fn knit_parameter_space()
#
# Public accessor for a command parameter's declared search domain, returned in
# structured form. This is the lazy parse+validate point: it reads the raw
# descriptor stored at declaration (the <ns>_2_<param>_domain token and its
# _domain_log flag), parses it with the shared grammar, and validates it against
# the parameter's declared type (so a type x kind error surfaces here, on first
# read, not at declaration). The parameter name is normalized (hyphen or
# underscore spelling). Returns status 1 with all outputs cleared when the
# parameter has no declared domain.
#
# The output arguments come first, in the order kind, type, lo, hi, values,
# step, log, glob; then the command and parameter.
#
# @param[out] __knit_ret1 Domain kind ("list", "range", or "glob").
# @param[out] __knit_ret2 The parameter's declared type.
# @param[out] __knit_ret3 Range lower bound (empty unless kind=range).
# @param[out] __knit_ret4 Range upper bound (empty unless kind=range).
# @param[out] __knit_ret5 Array of list values (empty unless kind=list).
# @param[out] __knit_ret6 Range step (empty when unset or kind!=range).
# @param[out] __knit_ret7 Log-scale flag ("true"/"false").
# @param[out] __knit_ret8 Glob pattern (empty unless kind=glob).
# @param[in] cmd Command the parameter belongs to (the mangled/registered name).
# @param[in] param Parameter name (hyphen or underscore spelling).
# @return 0 if the parameter has a declared domain, 1 otherwise.
# ------------------------------------------------------------------------------
knit_parameter_space() {
    # __knit_ret1/__knit_ret2 are scalar here but the parser above aliases the
    # same nameref names to arrays; shellcheck's file-global view conflates them.
    # shellcheck disable=SC2178
    local -n __knit_ret1=$1
    # shellcheck disable=SC2178
    local -n __knit_ret2=$2
    local -n __knit_ret3=$3
    local -n __knit_ret4=$4
    local -n __knit_ret5=$5
    local -n __knit_ret6=$6
    local -n __knit_ret7=$7
    local -n __knit_ret8=$8
    local cmd="$9" raw_param="${10}"

    # shellcheck disable=SC2178 # scalar here; parser aliases the same names to arrays
    __knit_ret1=""
    # shellcheck disable=SC2178
    __knit_ret2=""
    __knit_ret3=""; __knit_ret4=""
    __knit_ret5=(); __knit_ret6=""; __knit_ret7=""; __knit_ret8=""

    local __knit_param
    _knit_name_normalize __knit_param "${raw_param}"

    local __knit_domain_var="_KNIT_CMD_${cmd}_2_${__knit_param}_domain"
    if [[ ! -v "${__knit_domain_var}" || -z "${!__knit_domain_var}" ]]; then
        return 1
    fi
    local __knit_raw="${!__knit_domain_var}"
    local __knit_log="false"
    local __knit_log_var="_KNIT_CMD_${cmd}_2_${__knit_param}_domain_log"
    [[ -v "${__knit_log_var}" ]] && __knit_log="${!__knit_log_var}"
    local __knit_type_var="_KNIT_CMD_${cmd}_2_${__knit_param}_type"
    local __knit_type="${!__knit_type_var}"

    local -A __knit_space_desc
    local __knit_space_vals
    _knit_search_parse_literal __knit_space_desc __knit_space_vals "${__knit_raw}"
    _knit_search_validate_descriptor __knit_space_desc __knit_space_vals \
        "${__knit_type}" "${__knit_log}"

    # shellcheck disable=SC2178 # scalar here; parser aliases the same names to arrays
    __knit_ret1="${__knit_space_desc[kind]}"
    # shellcheck disable=SC2178
    __knit_ret2="${__knit_type}"
    __knit_ret3="${__knit_space_desc[lo]}"
    __knit_ret4="${__knit_space_desc[hi]}"
    __knit_ret5=("${__knit_space_vals[@]}")
    __knit_ret6="${__knit_space_desc[step]}"
    __knit_ret7="${__knit_log}"
    __knit_ret8="${__knit_space_desc[glob]}"
    return 0
}

# ------------------------------------------------------------------------------
# @fn knit_parameter_space_json()
#
# Print a command parameter's declared search domain as a compact JSON object
# (one fork), or the literal "null" when the parameter has no declared domain.
# The object has the keys kind, type, lo, hi, step, glob (strings), log
# (boolean), and values (array of strings). A convenient read for "describe
# --space" and the Bayesian-optimization plugin. Like knit_parameter_space, it
# parses and validates on read, so an invalid declared domain is fatal here.
#
# @param[in] cmd Command the parameter belongs to (the mangled/registered name).
# @param[in] param Parameter name (hyphen or underscore spelling).
# ------------------------------------------------------------------------------
knit_parameter_space_json() {
    local cmd="$1" param="$2"
    local __knit_j_kind __knit_j_type __knit_j_lo __knit_j_hi
    local __knit_j_values __knit_j_step __knit_j_log __knit_j_glob
    if ! knit_parameter_space \
        __knit_j_kind __knit_j_type __knit_j_lo __knit_j_hi __knit_j_values \
        __knit_j_step __knit_j_log __knit_j_glob "${cmd}" "${param}"; then
        printf 'null\n'
        return 0
    fi
    # shellcheck disable=SC2016 # $kind etc. are jq variables, not shell expansions
    knit_jq -cn \
        --arg kind "${__knit_j_kind}" \
        --arg type "${__knit_j_type}" \
        --arg lo   "${__knit_j_lo}" \
        --arg hi   "${__knit_j_hi}" \
        --arg step "${__knit_j_step}" \
        --arg glob "${__knit_j_glob}" \
        --argjson log "${__knit_j_log:-false}" \
        '{kind:$kind, type:$type, lo:$lo, hi:$hi, step:$step, glob:$glob, log:$log, values:$ARGS.positional}' \
        --args "${__knit_j_values[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_search_launch()
#
# Launch one tracked trial: invoke a fully-substituted downstream knit command
# line in-process, through the normal entry path, and return the child's
# recorded row id by nameref. The downstream line is one of:
#
#   submit ... -- <job> ...   a job submission
#   run ... -- <app> ...      a run
#   <command> ...             a plain command
#
# The engine stays opaque to the line: it forwards every argument verbatim to
# _knit_invoke_command (the same path knit() uses), so a dispatcher such as
# submit or run parses its own options and the target its parameters. The
# invocation runs in-process, inside the calling proposer's frame, so knit's
# existing recording writes the provenance "call" edge parent -> child by
# itself; the search core adds no edge type and no provenance hook.
#
# The child's row id is read from _KNIT_LAST_ROW_ID, which the recorder sets to
# each recorded invocation's id. It is empty when the child records no row (the
# experiment is not bootstrapped, or recording is disabled). The function returns
# the downstream line's own exit status, so a caller (the search loop) can see a
# plain command's or an app run's success or failure.
#
# @param[out] __knit_ret The child invocation's recorded row id (empty if none).
# @param[in] ... The downstream knit command line (command and its arguments).
# @return The exit status of the downstream invocation.
# ------------------------------------------------------------------------------
_knit_search_launch() {
    local -n __knit_ret=$1
    shift
    if [[ $# -eq 0 ]]; then
        knit_fatal "_knit_search_launch requires a downstream command line."
    fi
    __knit_ret=""
    # Clear first so we pick up only an id the child itself recorded (it stays
    # empty when the experiment is not bootstrapped), mirroring knit setup.
    _KNIT_LAST_ROW_ID=""
    local launch_status=0
    _knit_invoke_command "$@" || launch_status=$?
    __knit_ret="${_KNIT_LAST_ROW_ID}"
    return "${launch_status}"
}
