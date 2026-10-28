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

    # The caller's nameref target is an associative array, which shellcheck
    # cannot see through the nameref: it reads the [key]= entries as arithmetic
    # indices (SC2154) and the never-read keys as unused (SC2034).
    # shellcheck disable=SC2034,SC2154
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
# @fn knit_search_parse_token()
#
# Public accessor that parses one domain descriptor token into its structured
# form. The same grammar covers "{...}" list, "[lo..hi]" / "[lo..hi:step]"
# range, "@glob:<pattern>" glob, and "@file:<path>" file tokens. Callers MUST
# declare the first output as an associative array (declare -A) and the second
# as an ordinary array. A malformed or unrecognised token is fatal.
#
# @param[out] __knit_ret1 Associative array to receive the descriptor scalars:
#   keys kind (list|range|glob), lo, hi, step, glob.
# @param[out] __knit_ret2 Indexed array to receive the list values (empty unless
#   kind=list).
# @param[in] token The descriptor token to parse.
# ------------------------------------------------------------------------------
knit_search_parse_token() {
    # shellcheck disable=SC2178 # nameref to an assoc array
    local -n __knit_ret1=$1
    # shellcheck disable=SC2178 # nameref to an array
    local -n __knit_ret2=$2
    local tok="$3"
    local -A __desc
    local -a __vals
    _knit_search_parse_literal __desc __vals "${tok}"
    __knit_ret1=(
        [kind]="${__desc[kind]}"
        [lo]="${__desc[lo]}"
        [hi]="${__desc[hi]}"
        [step]="${__desc[step]}"
        [glob]="${__desc[glob]}"
    )
    __knit_ret2=("${__vals[@]}")
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
# @fn knit_search_launch()
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
knit_search_launch() {
    local -n __knit_ret=$1
    shift
    if [[ $# -eq 0 ]]; then
        knit_fatal "knit_search_launch requires a downstream command line."
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

# ------------------------------------------------------------------------------
# @fn knit_search_read_objective()
#
# Read one finished trial's objective value from the database, given the trial's
# recorded child row id (as returned by knit_search_launch) and the table/column
# that holds the objective. A trial is a chain of recorded rows linked by
# "call" edges in the provenance table: the launch id is the outer dispatcher's
# row (the jobs row for "submit", the runs row for "run"), while the objective is
# usually written by a descendant (the job body's row, the app's row). This
# function resolves the objective row by walking "call" edges breadth-first from
# the child id until it reaches a row that exists in the named table, then reads
# the named column from that row.
#
# The child id itself is tried first, so an objective recorded directly in the
# dispatcher's own table (no descendant) is read without a walk. The caller owns
# the policy of which table and column hold the objective (e.g. the Bayesian
# optimizer's leaf-first chain walk over declared outputs); this function owns
# only the generic row resolution and point read.
#
# Trust contract: only the id is SQL-escaped; table and column are interpolated
# into the query verbatim. They are expected to be registration-derived names
# (e.g. from knit_command_table and knit_output_type), the same trust knit places
# in table names throughout db.sh — do NOT pass an end-user string here.
#
# A missing objective row (no reachable row in the table) and a NULL/empty
# objective column (a crashed trial that recorded no value) are both reported as
# failure: the output is cleared and the return status is non-zero, so the caller
# can apply its failure policy.
#
# @param[out] __knit_ret The objective value (empty on failure).
# @param[in] child_id The trial's recorded child row id (from knit_search_launch).
# @param[in] table The table that holds the objective column.
# @param[in] column The objective column name.
# @return 0 when a non-empty objective value was read, 1 otherwise.
# ------------------------------------------------------------------------------
knit_search_read_objective() {
    local -n __knit_ret=$1
    local child_id="$2" table="$3" column="$4"
    __knit_ret=""
    [[ -z "${child_id}" || -z "${table}" || -z "${column}" ]] && return 1

    # Breadth-first walk over "call" edges from the child id. The provenance call
    # edges form a tree (each invocation has one caller), so a visited set and a
    # depth bound only guard against unexpected shapes.
    local -a frontier=("${child_id}")
    local -A visited=()
    local depth=0 max_depth=64
    local -a next
    local id esc exists targets target
    while [[ ${#frontier[@]} -gt 0 && ${depth} -lt ${max_depth} ]]; do
        next=()
        for id in "${frontier[@]}"; do
            [[ -v visited["${id}"] ]] && continue
            visited["${id}"]=1
            _knit_sql_escape esc "${id}"
            # A row with this id in the objective table ends the walk: read the
            # column (which may itself be NULL -> reported as failure below).
            exists="$(_knit_sqlite3 \
                "SELECT 1 FROM ${table} WHERE id='${esc}' LIMIT 1;" 2>/dev/null)" \
                || exists=""
            if [[ -n "${exists}" ]]; then
                __knit_ret="$(_knit_sqlite3 \
                    "SELECT ${column} FROM ${table} WHERE id='${esc}';" \
                    2>/dev/null)" || __knit_ret=""
                [[ -n "${__knit_ret}" ]] && return 0
                return 1
            fi
            # Not in the table: enqueue this id's call-edge targets.
            targets="$(_knit_sqlite3 \
                "SELECT target_id FROM ${_KNIT_PROV_TABLE} WHERE source_id='${esc}' AND edge_type='call';" \
                2>/dev/null)" || targets=""
            while IFS= read -r target; do
                [[ -n "${target}" ]] && next+=("${target}")
            done <<< "${targets}"
        done
        frontier=("${next[@]}")
        depth=$(( depth + 1 ))
    done
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_search_job_terminal_status()
#
# Read a job trial's terminal status from the jobs table, by row id. Returns 0
# and sets the output to "completed" (the job finished cleanly) or "failed" (the
# job ended in any other terminal state, "failed" or "killed"); returns 1 and
# clears the output while the job is not yet terminal (no row, "submitted", or
# "running"), so the loop keeps polling. The state column is written compute-side
# by the job before/after callbacks.
#
# @param[out] __knit_ret The terminal status ("completed" or "failed").
# @param[in] uuid The job's row id (its UUID).
# @return 0 if the job reached a terminal state, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_search_job_terminal_status() {
    local -n __knit_ret=$1
    local uuid="$2"
    local esc
    _knit_sql_escape esc "${uuid}"
    local state
    state="$(_knit_sqlite3 \
        "SELECT state FROM ${_KNIT_JOBS_TABLE} WHERE id='${esc}';" 2>/dev/null)" \
        || state=""
    case "${state}" in
        completed)     __knit_ret="completed"; return 0 ;;
        failed|killed) __knit_ret="failed";    return 0 ;;
        *)             __knit_ret="";          return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_search_loop_finish()
#
# Handle one finished trial: read its objective through the optional collector,
# then hand the outcome to the proposer's observe callback. The collector runs
# only when a collector function was given (the proposer wants the objective);
# the search core owns no reporting surface. The observe callback decides, by its
# return value, whether the campaign continues (0) or aborts (non-zero), so the
# failure policy stays proposer-specific (sweep "stop" aborts; sweep "continue"
# and BO "ignore"/"penalize" continue).
#
# @param[in] observe_fn The proposer's observe callback
#   (observe_fn <tag> <uuid> <status> <objective>).
# @param[in] collect_fn The optional collector callback (collect_fn <out> <uuid>),
#   or empty to skip the objective read.
# @param[in] tag    The proposer's opaque key for this trial (from ask).
# @param[in] uuid   The trial child's recorded row id.
# @param[in] status The trial's terminal status ("completed" or "failed").
# @return 0 to continue the campaign, non-zero to abort it (observe's verdict).
# ------------------------------------------------------------------------------
_knit_search_loop_finish() {
    local observe_fn="$1" collect_fn="$2" tag="$3" uuid="$4" status="$5"
    local _knit_loop_objective=""
    if [[ -n "${collect_fn}" ]]; then
        "${collect_fn}" _knit_loop_objective "${uuid}"
    fi
    "${observe_fn}" "${tag}" "${uuid}" "${status}" "${_knit_loop_objective}"
}

# ------------------------------------------------------------------------------
# @fn _knit_search_loop_job()
#
# The job-mode search loop: launch each trial as an ordinary submission and
# detect completion by polling the jobs table state column. Keeps up to
# <parallel> trials in flight and launches at most <budget> in total (empty
# budget means the proposer's ask exhaustion is the only limit). Between polls,
# when no trial finished, it waits <poll> seconds (through the overridable
# "sleep", so a test can drive it deterministically).
#
# @param[in] parallel   Maximum trials in flight at once (>= 1).
# @param[in] budget      Maximum trials to launch (empty for unbounded).
# @param[in] poll        Seconds to wait between polls when nothing finished.
# @param[in] ask_fn      Proposer ask callback (ask_fn <tag-out> <argv-out>;
#   returns 1 when exhausted).
# @param[in] observe_fn  Proposer observe callback (see _knit_search_loop_finish).
# @param[in] collect_fn  Optional collector callback (empty to skip).
# @return 0 on a completed campaign, 1 when the proposer aborted it.
# ------------------------------------------------------------------------------
_knit_search_loop_job() {
    local parallel="$1" budget="$2" poll="$3"
    local ask_fn="$4" observe_fn="$5" collect_fn="$6"
    local -A inflight=()
    local launched=0 stop_launching="" aborted=""
    local _knit_loop_tag
    local -a _knit_loop_argv
    local _knit_loop_uuid
    while true; do
        local headroom=$(( parallel - ${#inflight[@]} ))
        while [[ -z "${stop_launching}" && -z "${aborted}" ]] && (( headroom > 0 )); do
            if [[ -n "${budget}" ]] && (( launched >= budget )); then
                stop_launching=1; break
            fi
            _knit_loop_tag=""; _knit_loop_argv=()
            if ! "${ask_fn}" _knit_loop_tag _knit_loop_argv; then
                # The proposer offered no trial right now. This is NOT a
                # permanent stop: a parallel proposer (e.g. Ax in its model
                # phase) declines while trials are still in flight and proposes
                # again once their results arrive. Stop filling this round only;
                # the loop then waits for a completion and re-asks. Genuine
                # exhaustion is caught below: when nothing is in flight and the
                # ask still yields nothing, the inflight==0 guard ends the loop.
                break
            fi
            _knit_loop_uuid=""
            knit_search_launch _knit_loop_uuid "${_knit_loop_argv[@]}"
            launched=$(( launched + 1 ))
            if [[ -n "${_knit_loop_uuid}" ]]; then
                inflight["${_knit_loop_uuid}"]="${_knit_loop_tag}"
                headroom=$(( headroom - 1 ))
            fi
        done
        [[ -n "${aborted}" ]] && break
        # Nothing in flight after a fill means nothing more can be launched.
        (( ${#inflight[@]} == 0 )) && break
        local progressed="" u status
        for u in "${!inflight[@]}"; do
            if _knit_search_job_terminal_status status "${u}"; then
                if ! _knit_search_loop_finish "${observe_fn}" "${collect_fn}" \
                        "${inflight[$u]}" "${u}" "${status}"; then
                    aborted=1
                fi
                unset 'inflight[$u]'
                progressed=1
                [[ -n "${aborted}" ]] && break
            fi
        done
        [[ -n "${aborted}" ]] && break
        [[ -z "${progressed}" ]] && sleep "${poll}"
    done
    [[ -n "${aborted}" ]] && return 1
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_search_loop_app()
#
# The app-mode search loop: launch each trial's blocking "knit run" in the
# background and detect completion by reaping the next finished child with
# "wait -n". Keeps up to <parallel> runs in flight and launches at most <budget>
# in total (empty budget means the proposer's ask exhaustion is the only limit).
# Each background child writes its recorded row id to a temporary file and exits
# with the run's own status, so the loop learns both after the reap.
#
# @param[in] parallel   Maximum runs in flight at once (>= 1).
# @param[in] budget      Maximum trials to launch (empty for unbounded).
# @param[in] ask_fn      Proposer ask callback (ask_fn <tag-out> <argv-out>;
#   returns 1 when exhausted).
# @param[in] observe_fn  Proposer observe callback (see _knit_search_loop_finish).
# @param[in] collect_fn  Optional collector callback (empty to skip).
# @return 0 on a completed campaign, 1 when the proposer aborted it.
# ------------------------------------------------------------------------------
_knit_search_loop_app() {
    local parallel="$1" budget="$2"
    local ask_fn="$3" observe_fn="$4" collect_fn="$5"
    local -A pid_tag=() pid_file=()
    local launched=0 stop_launching="" aborted=""
    local _knit_loop_tag
    local -a _knit_loop_argv
    while true; do
        local headroom=$(( parallel - ${#pid_tag[@]} ))
        while [[ -z "${stop_launching}" && -z "${aborted}" ]] && (( headroom > 0 )); do
            if [[ -n "${budget}" ]] && (( launched >= budget )); then
                stop_launching=1; break
            fi
            _knit_loop_tag=""; _knit_loop_argv=()
            if ! "${ask_fn}" _knit_loop_tag _knit_loop_argv; then
                # Soft stop for this round only, not a permanent one: a parallel
                # proposer may decline while trials are in flight and propose
                # again after their results arrive (see _knit_search_loop_job).
                # The pid_tag==0 guard below ends the loop on genuine exhaustion.
                break
            fi
            local tmpf
            tmpf="$(mktemp)"
            # Run the blocking launch in a subshell: it writes the child row id to
            # the temp file and exits with the run's own status, so the reap below
            # recovers both from the background job.
            (
                _knit_loop_child_uuid=""
                knit_search_launch _knit_loop_child_uuid "${_knit_loop_argv[@]}"
                _knit_loop_child_status=$?
                printf '%s' "${_knit_loop_child_uuid}" > "${tmpf}"
                exit "${_knit_loop_child_status}"
            ) &
            local pid=$!
            pid_tag["${pid}"]="${_knit_loop_tag}"
            pid_file["${pid}"]="${tmpf}"
            launched=$(( launched + 1 ))
            headroom=$(( headroom - 1 ))
        done
        [[ -n "${aborted}" ]] && break
        (( ${#pid_tag[@]} == 0 )) && break
        local reaped="" wstat=0
        wait -n -p reaped "${!pid_tag[@]}"
        wstat=$?
        [[ -z "${reaped}" ]] && continue
        local tag="${pid_tag[$reaped]}" tmpf="${pid_file[$reaped]}"
        local uuid=""
        [[ -r "${tmpf}" ]] && IFS= read -r uuid < "${tmpf}"
        rm -f "${tmpf}"
        unset 'pid_tag[$reaped]' 'pid_file[$reaped]'
        local status="completed"
        (( wstat != 0 )) && status="failed"
        if ! _knit_search_loop_finish "${observe_fn}" "${collect_fn}" \
                "${tag}" "${uuid}" "${status}"; then
            aborted=1
        fi
        [[ -n "${aborted}" ]] && break
    done
    [[ -n "${aborted}" ]] && return 1
    return 0
}

# ------------------------------------------------------------------------------
# @fn knit_search_loop()
#
# The shared search loop: drive a proposer over a budget of trials, keeping up to
# --parallel in flight, launching each through knit_search_launch and detecting
# completion by the chosen mode. It owns budget accounting, in-flight tracking,
# completion detection, and routing a finished trial's outcome to the proposer;
# the proposer (the ask/observe callbacks) owns which assignment runs next and
# the failure policy, and an optional collector owns the objective read. Both
# proposers (the cartesian sweep and the Ax plugin) reuse this one loop.
#
# The proposer is two callbacks. ask yields the next trial, returning the
# proposer's opaque tag and the fully-substituted downstream command line (the
# argv knit_search_launch runs); it returns non-zero when it has no more trials.
# observe is told each finished trial's tag, child row id, terminal status, and
# objective, and returns non-zero to abort the campaign (how a failure maps to an
# abort is the proposer's policy). The optional collector reads one finished
# child's objective; it runs only when given.
#
# Completion detection has two modes: "job" polls the jobs table state column
# (ordinary submissions, possibly many queued at once); "app" reaps backgrounded
# "knit run" children with "wait -n".
#
# @param[in] ... Options: --mode <job|app> (required), --ask <fn> (required),
#   --observe <fn> (required), --collect <fn> (optional), --parallel <K>
#   (default 1), --budget <N> (default unbounded), --poll <seconds> (job mode,
#   default _KNIT_SCHED_POLL_INTERVAL).
# @return 0 on a completed campaign, 1 when the proposer aborted it.
# ------------------------------------------------------------------------------
knit_search_loop() {
    local mode="" parallel="1" budget="" poll="${_KNIT_SCHED_POLL_INTERVAL}"
    local ask_fn="" observe_fn="" collect_fn=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)     mode="$2";       shift 2 ;;
            --parallel) parallel="$2";   shift 2 ;;
            --budget)   budget="$2";     shift 2 ;;
            --poll)     poll="$2";       shift 2 ;;
            --ask)      ask_fn="$2";     shift 2 ;;
            --observe)  observe_fn="$2"; shift 2 ;;
            --collect)  collect_fn="$2"; shift 2 ;;
            *) knit_fatal "knit_search_loop: unknown option '%s'." "$1" ;;
        esac
    done

    case "${mode}" in
        job|app) ;;
        *) knit_fatal "knit_search_loop requires --mode job|app (got '%s')." "${mode}" ;;
    esac
    [[ -n "${ask_fn}" ]] || knit_fatal "knit_search_loop requires --ask <function>."
    [[ -n "${observe_fn}" ]] || knit_fatal "knit_search_loop requires --observe <function>."
    if ! [[ "${parallel}" =~ ^[0-9]+$ ]] || (( parallel < 1 )); then
        knit_fatal "knit_search_loop --parallel must be a positive integer (got '%s')." "${parallel}"
    fi
    if [[ -n "${budget}" ]] && ! [[ "${budget}" =~ ^[0-9]+$ ]]; then
        knit_fatal "knit_search_loop --budget must be a non-negative integer (got '%s')." "${budget}"
    fi

    if [[ "${mode}" == "job" ]]; then
        _knit_search_loop_job "${parallel}" "${budget}" "${poll}" \
            "${ask_fn}" "${observe_fn}" "${collect_fn}"
    else
        _knit_search_loop_app "${parallel}" "${budget}" \
            "${ask_fn}" "${observe_fn}" "${collect_fn}"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_search_resolve_fill()
#
# Resolve, for one parameter, whether it varies in the campaign and from where.
# This is the shared "Which parameters vary" rule that both proposers reuse (each
# sets only its own default --fill); it does NOT read or enumerate a declared
# domain (how a varying parameter's domain is used -- enumerate or sample -- stays
# with the proposer, as does the enumerability check). The result is one of:
#
#   explicit   the call site carries a concrete value or a set literal for this
#              parameter, so the proposer uses what the line already says;
#   sweep      vary this parameter from its declared domain;
#   default    leave this parameter at its default value.
#
# The precedence (highest first): an explicit value/token always wins; then a
# per-parameter @sweep / @default token; then the --fill policy for an otherwise
# unspecified parameter. Under --fill sweep an unspecified parameter varies only
# when it has a declared domain -- a parameter with no declared domain stays at
# its default under either policy (it is never "the space"). The per-parameter
# token classification (explicit / sweep / default / unspecified) comes from the
# proposer's own call-site scan; this helper only applies the precedence.
#
# @param[out] __knit_ret The resolution ("explicit", "sweep", or "default").
# @param[in] fill The --fill policy for an unspecified parameter ("default" or
#   "sweep").
# @param[in] token How the call site referenced this parameter: "explicit" (a
#   concrete value or set literal), "sweep" (@sweep), "default" (@default), or
#   "unspecified" (nothing).
# @param[in] has_domain "true" if the parameter has a declared domain, else
#   "false".
# ------------------------------------------------------------------------------
knit_search_resolve_fill() {
    local -n __knit_ret=$1
    local fill="$2" token="$3" has_domain="$4"
    case "${fill}" in
        default|sweep) ;;
        *) knit_fatal "knit_search_resolve_fill: --fill must be default or sweep (got '%s')." "${fill}" ;;
    esac
    case "${token}" in
        explicit) __knit_ret="explicit" ;;
        sweep)    __knit_ret="sweep" ;;
        default)  __knit_ret="default" ;;
        unspecified)
            if [[ "${fill}" == "sweep" && "${has_domain}" == "true" ]]; then
                __knit_ret="sweep"
            else
                __knit_ret="default"
            fi
            ;;
        *) knit_fatal "knit_search_resolve_fill: unknown token classification '%s'." "${token}" ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn knit_search_scan()
#
# Classify a downstream token list left to right into an ordered list of axes
# and a reconstruction template, without introspecting the downstream command
# and without enumerating literal axes. A token is handled only when it starts
# with "{", "[", or "@" and its preceding "--option" is not named in
# --passthrough; every other token is literal and is placed in the template
# verbatim. Each handled token is classified:
#
#   - "{...}" / "[...]" / "@glob:..." / "@file:..." -> kind "literal";
#   - "@sweep" -> a marker to sweep the declared domain (kind "sweep");
#   - "@default" -> a marker to pin at the default (kind "default");
#   - any other "@..." -> a fatal (unknown directive).
#
# An axis is named by its preceding "--option" (hyphens folded to underscores);
# a swept positional token is named "#<index>" by its position in the
# downstream. The "seen" map records, for every "--option" that carried a
# value, how the call site referenced it ("explicit", "sweep", or "default");
# a literal axis folds to "explicit". The inline "--opt=value" form is
# self-contained and recorded as "explicit". All four outputs are reset on
# entry, so the "seen" map need not be empty, but it MUST be declared as an
# associative array (declare -A).
#
# Unlike _knit_sweep_scan, this function stores the verbatim token text (not
# an enumerated value list) in rawtokens-out for literal axes. Callers that
# need the enumerated list enumerate each raw token themselves.
#
# @param[out] __knit_ret1 Name of the array to receive the reconstruction
#   template (a copy of the downstream tokens).
# @param[out] __knit_ret2 Name of the array to receive the axis descriptors,
#   each the string "<kind> <slot> <name>".
# @param[out] __knit_ret3 Name of the array to receive per-axis raw tokens:
#   the verbatim token text for a "literal" axis, empty for "sweep"/"default".
# @param[out] __knit_ret4 Name of the associative array to receive the seen
#   map (option -> "explicit"|"sweep"|"default").
# @param[in] passthrough_csv Comma-separated option names whose values are
#   never treated as sweep-syntax (may be empty).
# @param[in] ... The downstream tokens.
# ------------------------------------------------------------------------------
knit_search_scan() {
    # shellcheck disable=SC2178 # nameref to an array
    local -n __knit_ret1=$1
    # shellcheck disable=SC2178 # nameref to an array
    local -n __knit_ret2=$2
    # shellcheck disable=SC2178 # nameref to an array
    local -n __knit_ret3=$3
    # shellcheck disable=SC2178 # nameref to an associative array
    local -n __knit_ret4=$4
    local passthrough_csv="$5"
    shift 5
    local -a down=("$@")

    __knit_ret1=("${down[@]}")
    __knit_ret2=()
    __knit_ret3=()
    # Reset the seen map too, so all four outputs are cleared for the caller
    # (clearing a nameref to an associative array keeps its -A attribute).
    # shellcheck disable=SC2178 # nameref to an associative array
    __knit_ret4=()

    local -A pass=()
    if [[ -n "${passthrough_csv}" ]]; then
        local IFS=',' _pt_entry _pt_norm
        for _pt_entry in ${passthrough_csv}; do
            _pt_entry="${_pt_entry#"${_pt_entry%%[![:space:]]*}"}"
            _pt_entry="${_pt_entry%"${_pt_entry##*[![:space:]]}"}"
            [[ -z "${_pt_entry}" ]] && continue
            _knit_name_normalize _pt_norm "${_pt_entry}"
            pass["${_pt_norm}"]=1
        done
    fi

    local _tok _prev_opt="" _akind _aname _rawtoken _inline_opt
    local _is_candidate _protected
    local _idx
    for ((_idx=0; _idx<${#down[@]}; _idx++)); do
        _tok="${down[_idx]}"
        if [[ "${_tok}" == --* ]]; then
            if [[ "${_tok}" == *=* ]]; then
                _knit_name_normalize _inline_opt "${_tok#--}"
                _inline_opt="${_inline_opt%%=*}"
                [[ -n "${_inline_opt}" ]] && __knit_ret4["${_inline_opt}"]="explicit"
                _prev_opt=""
            elif [[ "${_tok}" == "--" ]]; then
                _prev_opt=""
            else
                _knit_name_normalize _prev_opt "${_tok#--}"
            fi
            continue
        fi

        _is_candidate="false"
        case "${_tok}" in '{'*|'['*|'@'*) _is_candidate="true" ;; esac
        _protected="false"
        [[ -n "${_prev_opt}" && -v pass["${_prev_opt}"] ]] && _protected="true"

        if [[ "${_is_candidate}" == "true" && "${_protected}" == "false" ]]; then
            _akind=""
            case "${_tok}" in
                '@sweep')            _akind="sweep" ;;
                '@default')          _akind="default" ;;
                '@glob:'*|'@file:'*) _akind="literal" ;;
                '@'*)
                    knit_fatal "Unknown sweep directive '%s' (expected @sweep, @default, @glob:<pattern>, or @file:<path>)." "${_tok}"
                    ;;
                *) _akind="literal" ;;
            esac
            if [[ -n "${_prev_opt}" ]]; then _aname="${_prev_opt}"; else _aname="#${_idx}"; fi
            _rawtoken=""
            [[ "${_akind}" == "literal" ]] && _rawtoken="${_tok}"
            __knit_ret2+=("${_akind} ${_idx} ${_aname}")
            __knit_ret3+=("${_rawtoken}")
            if [[ -n "${_prev_opt}" ]]; then
                __knit_ret4["${_prev_opt}"]="${_akind/literal/explicit}"
            fi
        elif [[ -n "${_prev_opt}" ]]; then
            __knit_ret4["${_prev_opt}"]="explicit"
        fi
        _prev_opt=""
    done
}

# ------------------------------------------------------------------------------
# @fn knit_search_group_forward()
#
# Forward a campaign --group label into one trial's downstream command line, in
# place, so a job trial lands in the existing jobs.group column (which makes
# "submit next --group" and "remove --group" operate on the campaign with no new
# code). The group is a submission field, so it is inserted among the submit
# options -- right after the leading "submit" or "prepare" token, before its
# "--". Both are job dispatchers that share the submit option surface (and so
# accept --group); a sweep that prepares a durable product uses the "prepare"
# form. The line is left unchanged when the group is empty or the line is neither
# a submit nor a prepare line (a "run ... -- app" or a bare command has no
# scheduler, so its group lives only on the parent row and the call edges). The
# parent row itself records the group automatically, since a proposer declares
# --group as an ordinary optional parameter.
#
# @param[in,out] __knit_argv Name of the array holding the downstream argv.
# @param[in] group The campaign group label (empty to leave the line unchanged).
# ------------------------------------------------------------------------------
knit_search_group_forward() {
    local -n __knit_argv=$1
    local group="$2"
    [[ -z "${group}" ]] && return 0
    case "${__knit_argv[0]}" in
        submit|prepare) ;;
        *) return 0 ;;
    esac
    __knit_argv=( "${__knit_argv[0]}" "--group" "${group}" "${__knit_argv[@]:1}" )
}

# ------------------------------------------------------------------------------
# @fn knit_search_resolve_target()
#
# Resolve the downstream target from the downstream token list: the command
# whose parameters a search proposer introspects (to resolve declared domains
# or @sweep markers), plus the dispatcher and target display names. The mapping
# mirrors how the downstream is actually run:
#
#   submit|prepare ... -- <job> ...  -> submit:<job>
#   run ... -- <app> ...             -> run:<app>
#   <command> ...                    -> the command itself
#
# The mangled command is empty when a submit/prepare/run line carries no job or
# app after its inner "--" (the downstream dispatcher reports the error when the
# line is actually run), so the caller can still record the dispatcher name.
#
# @param[out] __knit_ret1 Mangled command name to introspect (empty if none).
# @param[out] __knit_ret2 Dispatcher display name (submit/prepare/run, or the
#   command name for a bare command).
# @param[out] __knit_ret3 Target display name (the job/app name, or the command
#   name for a bare command).
# @param[in] ... The downstream tokens.
# ------------------------------------------------------------------------------
knit_search_resolve_target() {
    # shellcheck disable=SC2178 # scalar nameref outputs, not arrays
    local -n __knit_ret1=$1
    # shellcheck disable=SC2178
    local -n __knit_ret2=$2
    # shellcheck disable=SC2178
    local -n __knit_ret3=$3
    shift 3
    local -a down=("$@")
    # shellcheck disable=SC2178 # scalar nameref outputs, not arrays
    __knit_ret1=""
    # shellcheck disable=SC2178
    __knit_ret2=""
    # shellcheck disable=SC2178
    __knit_ret3=""
    [[ ${#down[@]} -eq 0 ]] && return 0

    local d0="${down[0]}" __d0n
    _knit_name_normalize __d0n "${d0}"
    case "${__d0n}" in
        submit|prepare|run)
            # shellcheck disable=SC2178
            __knit_ret2="${d0}"
            local k inner=-1
            for ((k=1; k<${#down[@]}; k++)); do
                if [[ "${down[k]}" == "--" ]]; then
                    inner=$((k+1)); break
                fi
            done
            (( inner < 0 || inner >= ${#down[@]} )) && return 0
            # shellcheck disable=SC2178
            __knit_ret3="${down[inner]}"
            local prefix="submit"
            [[ "${__d0n}" == "run" ]] && prefix="run"
            local __cmd
            _knit_command_mangle __cmd "${prefix}" "${down[inner]}"
            # shellcheck disable=SC2178
            __knit_ret1="${__cmd}"
            ;;
        *)
            local __cmd __consumed
            # shellcheck disable=SC2034 # consumed count unused here
            _knit_resolve_command_tokens \
                __cmd __consumed "${down[@]}"
            # shellcheck disable=SC2178
            __knit_ret1="${__cmd}"
            local demangled
            demangled=$(_knit_command_demangle "${__cmd}")
            # shellcheck disable=SC2178
            __knit_ret2="${demangled}"
            # shellcheck disable=SC2178
            __knit_ret3="${demangled}"
            ;;
    esac
}
