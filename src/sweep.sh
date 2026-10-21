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
# @fn _knit_sweep_expand_glob()
#
# Expand a "@glob:<pattern>" axis into its list of matching paths, at scan time.
# Pathname expansion is done with nullglob on (so a non-matching pattern yields
# an empty list, not the literal pattern), and a glob that matches nothing is a
# fatal: a zero-value axis would collapse the whole product to zero runs, which
# is almost always a mistake (a typo or the wrong working directory).
#
# @param[out] __knit_ret Name of the array to receive the matching paths.
# @param[in] pattern The glob pattern (already stripped of its "@glob:" prefix).
# ------------------------------------------------------------------------------
_knit_sweep_expand_glob() {
    # shellcheck disable=SC2178 # nameref output assigned as an array
    local -n __knit_ret=$1
    local pattern="$2"
    local had_nullglob="off"
    shopt -q nullglob && had_nullglob="on"
    shopt -s nullglob
    local -a matches
    # shellcheck disable=SC2206 # intentional pathname expansion of the glob pattern
    matches=( ${pattern} )
    [[ "${had_nullglob}" == "off" ]] && shopt -u nullglob
    if [[ ${#matches[@]} -eq 0 ]]; then
        knit_fatal "Glob '%s' matched no files." "${pattern}"
    fi
    __knit_ret=("${matches[@]}")
}

# ------------------------------------------------------------------------------
# @fn _knit_sweep_range_grid()
#
# Enumerate a range descriptor into its concrete grid of values. Two cases:
#
#   - no step ("[lo..hi]"): an integer grid with step 1, ascending or descending
#     (lo may be greater than hi). The bounds must be integers; a bare real
#     interval is bounds-only (a BO samples it, a sweep cannot enumerate it) and
#     is a fatal with the fix message.
#   - an explicit step ("[lo..hi:step]"): a linear grid from lo toward hi by the
#     step magnitude (integer or real; real arithmetic is done with awk so a
#     fractional step lands exactly). Descending is allowed (lo greater than hi).
#
# @param[out] __knit_ret Name of the array to receive the grid values.
# @param[in] lo The low (first) bound.
# @param[in] hi The high (last) bound.
# @param[in] step The step, or empty for the integer step-1 grid.
# @param[in] token The original token, for error messages.
# ------------------------------------------------------------------------------
_knit_sweep_range_grid() {
    # shellcheck disable=SC2178 # nameref output assigned as an array
    local -n __knit_ret=$1
    local lo="$2" hi="$3" step="$4" token="$5"
    local -a grid=()
    if [[ -z "${step}" ]]; then
        if ! knit_type_check integer "${lo}" || ! knit_type_check integer "${hi}"; then
            knit_fatal "Cannot sweep '%s': a bare [lo..hi] enumerates an integer grid (step 1). Give an explicit step '[lo..hi:step]' to enumerate a real interval." "${token}"
        fi
        local v
        if (( lo <= hi )); then
            for (( v=lo; v<=hi; v++ )); do grid+=("${v}"); done
        else
            for (( v=lo; v>=hi; v-- )); do grid+=("${v}"); done
        fi
    else
        if ! knit_type_check real "${lo}" || ! knit_type_check real "${hi}" \
            || ! knit_type_check real "${step}"; then
            knit_fatal "Range '%s' has a non-numeric bound or step." "${token}"
        fi
        local line
        while IFS= read -r line; do
            grid+=("${line}")
        done < <(awk -v lo="${lo}" -v hi="${hi}" -v step="${step}" 'BEGIN {
            s = step; if (s < 0) s = -s;
            if (s == 0) { exit 2 }
            dir = (lo <= hi) ? 1 : -1;
            n = int(((hi - lo) * dir) / s + 1e-9);
            for (i = 0; i <= n; i++) { printf("%g\n", lo + dir * s * i); }
        }')
        if [[ ${#grid[@]} -eq 0 ]]; then
            knit_fatal "Range '%s' has a zero or invalid step." "${token}"
        fi
    fi
    __knit_ret=("${grid[@]}")
}

# ------------------------------------------------------------------------------
# @fn _knit_sweep_enumerate()
#
# Enumerate one literal axis descriptor token into its concrete list of values.
# The token is parsed through the shared search-core parser, then the parsed
# descriptor is enumerated by kind: a list (or @file) is taken verbatim, a glob
# is expanded against the filesystem now, and a range is turned into its grid
# (see _knit_sweep_range_grid). This is the one point where the sweep turns a
# parsed descriptor into values; search-core deliberately leaves enumeration to
# the proposer.
#
# @param[out] __knit_ret Name of the array to receive the value list.
# @param[in] token The literal descriptor token ("{...}", "[...]", "@glob:...",
#   or "@file:...").
# ------------------------------------------------------------------------------
_knit_sweep_enumerate() {
    # shellcheck disable=SC2178 # nameref output assigned as an array
    local -n __knit_ret=$1
    local token="$2"
    local -A desc
    local -a vals
    _knit_search_parse_literal desc vals "${token}"
    # The temp passed to the sub-enumerators must not share a name with any local
    # they declare, or their output nameref would resolve to their own local
    # instead (the nameref-shadow-collision gotcha): _knit_sweep_range_grid uses
    # "grid", _knit_sweep_expand_glob uses "matches", so "enumerated" is safe.
    local -a enumerated
    case "${desc[kind]}" in
        list)  enumerated=("${vals[@]}") ;;
        glob)  _knit_sweep_expand_glob enumerated "${desc[glob]}" ;;
        range) _knit_sweep_range_grid enumerated \
                   "${desc[lo]}" "${desc[hi]}" "${desc[step]}" "${token}" ;;
        *)     knit_fatal "Internal error: descriptor '%s' has no kind." "${token}" ;;
    esac
    __knit_ret=("${enumerated[@]}")
}

# ------------------------------------------------------------------------------
# @fn _knit_sweep_scan()
#
# Scan a downstream token list left to right into an ordered list of axes and a
# reconstruction template, without introspecting the downstream command. A token
# is sweeper-handled only when it starts with "{", "[", or "@" and its preceding
# "--option" is not named in --passthrough; every other token is literal and is
# left in the template verbatim. Each handled token is classified:
#
#   - "{...}" / "[...]" / "@glob:..." / "@file:..." -> a literal axis: parsed and
#     enumerated now into a value list (kind "literal");
#   - "@sweep" -> a marker to sweep the parameter's declared domain, resolved in
#     a later milestone (kind "sweep", empty value list here);
#   - "@default" -> a marker to pin the parameter at its default (kind "default");
#   - any other "@..." -> a fatal (unknown directive).
#
# An axis is named by its preceding "--option" (hyphens folded to underscores);
# a swept positional token is named "#<index>" by its position in the downstream.
# The "seen" map records, for every "--option" that carried a value, how the call
# site referenced it ("explicit", "sweep", or "default"), so declared-domain
# resolution (a later milestone) knows which parameters were specified. The
# inline "--opt=value" form is self-contained and never swept (use the separate
# "--opt {...}" form to sweep a value); it is recorded as "explicit".
#
# Output arrays are parallel: axis i is described by __knit_ret2[i] (the string
# "<kind> <template-index> <name>") and its value list is __knit_ret3[i] (newline
# joined; empty for a "sweep"/"default" marker). The caller MUST pass a freshly
# declared associative array for the "seen" map.
#
# @param[out] __knit_ret1 Name of the array to receive the reconstruction
#   template (a copy of the downstream tokens; the odometer overwrites each
#   axis's template slot with its current value).
# @param[out] __knit_ret2 Name of the array to receive the axis descriptors.
# @param[out] __knit_ret3 Name of the array to receive the per-axis value lists.
# @param[out] __knit_ret4 Name of the associative array to receive the seen map.
# @param[in] passthrough_csv Comma-separated option names whose values are never
#   treated as sweep-syntax (may be empty).
# @param[in] ... The downstream tokens.
# ------------------------------------------------------------------------------
_knit_sweep_scan() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local -n __knit_ret3=$3
    local -n __knit_ret4=$4
    local passthrough_csv="$5"
    shift 5
    local -a down=("$@")

    __knit_ret1=("${down[@]}")
    __knit_ret2=()
    __knit_ret3=()

    # Build the set of protected option names from --passthrough.
    local -A pass=()
    if [[ -n "${passthrough_csv}" ]]; then
        local IFS=',' raw pname
        for raw in ${passthrough_csv}; do
            raw="${raw#"${raw%%[![:space:]]*}"}"
            raw="${raw%"${raw##*[![:space:]]}"}"
            [[ -z "${raw}" ]] && continue
            _knit_name_normalize pname "${raw}"
            pass["${pname}"]=1
        done
    fi

    local i token prev_opt=""
    for ((i=0; i<${#down[@]}; i++)); do
        token="${down[i]}"
        # An option token sets the context for the value token that follows it.
        # The inline "--opt=value" form is self-contained (its value is never
        # swept), and the bare "--" separator carries no value.
        if [[ "${token}" == --* ]]; then
            if [[ "${token}" == *=* ]]; then
                local inline_opt
                _knit_name_normalize inline_opt "${token#--}"
                inline_opt="${inline_opt%%=*}"
                [[ -n "${inline_opt}" ]] && __knit_ret4["${inline_opt}"]="explicit"
                prev_opt=""
            elif [[ "${token}" == "--" ]]; then
                prev_opt=""
            else
                _knit_name_normalize prev_opt "${token#--}"
            fi
            continue
        fi

        # A value (or positional) token. It is swept only when it looks like
        # sweep-syntax and its option is not protected by --passthrough.
        local is_candidate="false"
        case "${token}" in '{'*|'['*|'@'*) is_candidate="true" ;; esac
        local protected="false"
        [[ -n "${prev_opt}" && -v pass["${prev_opt}"] ]] && protected="true"

        if [[ "${is_candidate}" == "true" && "${protected}" == "false" ]]; then
            local akind=""
            case "${token}" in
                '@sweep')            akind="sweep" ;;
                '@default')          akind="default" ;;
                '@glob:'*|'@file:'*) akind="literal" ;;
                '@'*)
                    knit_fatal "Unknown sweep directive '%s' (expected @sweep, @default, @glob:<pattern>, or @file:<path>)." "${token}"
                    ;;
                *) akind="literal" ;;  # {...} or [...]
            esac
            local aname
            if [[ -n "${prev_opt}" ]]; then aname="${prev_opt}"; else aname="#${i}"; fi
            local joined=""
            if [[ "${akind}" == "literal" ]]; then
                local -a vlist
                _knit_sweep_enumerate vlist "${token}"
                printf -v joined '%s\n' "${vlist[@]}"
                joined="${joined%$'\n'}"
            fi
            __knit_ret2+=("${akind} ${i} ${aname}")
            __knit_ret3+=("${joined}")
            if [[ -n "${prev_opt}" ]]; then
                __knit_ret4["${prev_opt}"]="${akind/literal/explicit}"
            fi
        elif [[ -n "${prev_opt}" ]]; then
            # A concrete value (or a protected passthrough value): the option is
            # specified with an explicit value, so it never varies from a domain.
            __knit_ret4["${prev_opt}"]="explicit"
        fi
        prev_opt=""
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_sweep_resolve_target()
#
# Resolve the downstream target from the downstream token list: the command whose
# parameters the sweep introspects to resolve a declared domain (@sweep /
# --fill sweep), plus the dispatcher and target display names recorded on the
# sweeps row. The mapping mirrors how the downstream is actually run:
#
#   submit|prepare ... -- <job> ...  -> submit:<job>  (prepare reuses submit's jobs)
#   run ... -- <app> ...             -> run:<app>
#   <command> ...                    -> the command itself (lazy-discovered, so a
#                                       colon-nested name like "metadata store"
#                                       resolves)
#
# The mangled command is empty when a submit/prepare/run line carries no job or
# app after its inner "--" (the downstream dispatcher reports that error when the
# line is run), so the caller can still record the dispatcher without a target.
#
# @param[out] __knit_ret1 Mangled command name to introspect (empty if none).
# @param[out] __knit_ret2 Dispatcher display name (submit/prepare/run, or the
#   command name for a bare command).
# @param[out] __knit_ret3 Target display name (the job/app name, or the command
#   name for a bare command).
# @param[in] ... The downstream tokens.
# ------------------------------------------------------------------------------
_knit_sweep_resolve_target() {
    local -n __knit_ret_mangled=$1
    local -n __knit_ret_disp=$2
    local -n __knit_ret_tgt=$3
    shift 3
    local -a down=("$@")
    __knit_ret_mangled=""; __knit_ret_disp=""; __knit_ret_tgt=""
    [[ ${#down[@]} -eq 0 ]] && return 0

    local d0="${down[0]}" d0n
    _knit_name_normalize d0n "${d0}"
    case "${d0n}" in
        submit|prepare|run)
            __knit_ret_disp="${d0}"
            local k inner=-1
            for ((k=1; k<${#down[@]}; k++)); do
                if [[ "${down[k]}" == "--" ]]; then inner=$((k+1)); break; fi
            done
            (( inner < 0 || inner >= ${#down[@]} )) && return 0
            __knit_ret_tgt="${down[inner]}"
            local prefix="submit"
            [[ "${d0n}" == "run" ]] && prefix="run"
            local mangled
            _knit_command_mangle mangled "${prefix}" "${down[inner]}"
            __knit_ret_mangled="${mangled}"
            ;;
        *)
            local mangled
            # shellcheck disable=SC2034 # the consumed count is unused here
            local consumed
            _knit_resolve_command_tokens mangled consumed "${down[@]}"
            __knit_ret_mangled="${mangled}"
            local demangled
            demangled=$(_knit_command_demangle "${mangled}")
            __knit_ret_disp="${demangled}"
            __knit_ret_tgt="${demangled}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_sweep_enumerate_domain()
#
# Enumerate a parameter's declared search domain into its concrete value list,
# applying the enumerability gate the proposer owns. A real range (kind "range",
# type "real") is bounds-only (a Bayesian-optimization proposer samples it; a
# sweep cannot enumerate it), so asking to sweep one is a fatal with the fix
# message. Every other declared domain (a list, a glob, an enum list, or an
# integer range) enumerates like a call-site literal of the same shape.
#
# @param[out] __knit_ret Name of the array to receive the value list.
# @param[in] mangled The command the parameter belongs to (mangled name).
# @param[in] param The parameter name (normalized).
# ------------------------------------------------------------------------------
_knit_sweep_enumerate_domain() {
    # shellcheck disable=SC2178 # nameref output assigned as an array
    local -n __knit_ret=$1
    local mangled="$2" param="$3"
    # shellcheck disable=SC2034 # log is an unused slot of knit_parameter_space's output
    local kind type lo hi step log glob
    local -a values
    if ! knit_parameter_space kind type lo hi values step log glob \
        "${mangled}" "${param}"; then
        knit_fatal "Internal error: '%s' has no declared domain to enumerate." "${param}"
    fi
    if [[ "${kind}" == "range" && "${type}" == "real" ]]; then
        local raw_var="_KNIT_CMD_${mangled}_2_${param}_domain"
        knit_fatal "Cannot sweep '%s': its declared --domain '%s' is a real interval (bounds only). Give %s on the command line (--%s <value> or --%s '{...}'), or declare it with a list --domain '{...}' to make it enumerable." \
            "${param}" "${!raw_var}" "${param}" "${param}" "${param}"
    fi
    local -a enumerated
    case "${kind}" in
        list) enumerated=("${values[@]}") ;;
        glob) _knit_sweep_expand_glob enumerated "${glob}" ;;
        range)
            local token
            if [[ -n "${step}" ]]; then token="[${lo}..${hi}:${step}]"; else token="[${lo}..${hi}]"; fi
            _knit_sweep_range_grid enumerated "${lo}" "${hi}" "${step}" "${token}"
            ;;
        *) knit_fatal "Internal error: domain of '%s' has no kind." "${param}" ;;
    esac
    __knit_ret=("${enumerated[@]}")
}

# ------------------------------------------------------------------------------
# @fn _knit_sweep_resolve_domains()
#
# Resolve the declared-domain axes (@sweep / @default / --fill) against the
# downstream target's parameters, splicing the results into the M2 scan. This is
# the one point where the sweep introspects the target, and it runs only when it
# must: --fill sweep, or a @sweep/@default marker at the call site. With --fill
# default and no marker it returns at once, having read nothing.
#
# For each target parameter, the call-site classification (explicit / sweep /
# default / unspecified, from the seen map) and the parameter's declared-domain
# presence feed the shared _knit_search_resolve_fill precedence rule:
#   - explicit: left as the M2 scan already has it (a literal axis, or a scalar
#     that passes through);
#   - sweep: enumerate the declared domain (via _knit_sweep_enumerate_domain) and
#     either fill the call-site @sweep marker axis in place, or, for a parameter
#     left unspecified under --fill sweep, append a new "--param <value>" axis to
#     the template;
#   - default: a call-site @default marker is pinned to the resolved default value
#     in the template (and drops out as an axis); an unspecified parameter keeps
#     its default, which the downstream fills when the reconstructed line runs.
# An explicit @sweep on a parameter with no declared domain is a fatal; a @sweep /
# @default naming a parameter the target does not have is a fatal.
#
# @param[in,out] __knit_ret1 Name of the reconstruction template array.
# @param[in,out] __knit_ret2 Name of the axis-descriptor array.
# @param[in,out] __knit_ret3 Name of the per-axis value-list array.
# @param[in] __knit_seen Name of the seen map (option -> classification).
# @param[in] fill The --fill policy ("default" or "sweep").
# @param[in] mangled The resolved downstream target (mangled command name).
# ------------------------------------------------------------------------------
_knit_sweep_resolve_domains() {
    # shellcheck disable=SC2178 # nameref outputs used as arrays
    local -n __knit_ret1=$1
    # shellcheck disable=SC2178
    local -n __knit_ret2=$2
    # shellcheck disable=SC2178
    local -n __knit_ret3=$3
    local -n __knit_seen=$4
    local fill="$5" mangled="$6"

    # Gate: introspect only when there is something to resolve.
    local need="false" spec
    [[ "${fill}" == "sweep" ]] && need="true"
    if [[ "${need}" == "false" ]]; then
        for spec in "${__knit_ret2[@]}"; do
            case "${spec}" in "sweep "*|"default "*) need="true"; break ;; esac
        done
    fi
    [[ "${need}" == "false" ]] && return 0

    if ! _knit_set_find _KNIT_COMMANDS "${mangled}"; then
        knit_fatal "Cannot introspect the downstream target for --fill sweep / @sweep: '%s' is not a known command." "${mangled}"
    fi

    # Index the call-site @sweep/@default markers by parameter name.
    local -A marker_idx=() marker_slot=()
    local i kind slot name
    for ((i=0; i<${#__knit_ret2[@]}; i++)); do
        read -r kind slot name <<< "${__knit_ret2[i]}"
        if [[ "${kind}" == "sweep" || "${kind}" == "default" ]]; then
            marker_idx["${name}"]="${i}"
            marker_slot["${name}"]="${slot}"
        fi
    done

    local -a params
    knit_command_parameters params "${mangled}"
    local -A remove=()
    local p token has_domain resolved
    for p in "${params[@]}"; do
        token="${__knit_seen[${p}]:-unspecified}"
        has_domain="false"
        local dvar="_KNIT_CMD_${mangled}_2_${p}_domain"
        [[ -v "${dvar}" && -n "${!dvar}" ]] && has_domain="true"
        _knit_search_resolve_fill resolved "${fill}" "${token}" "${has_domain}"
        case "${resolved}" in
            explicit) ;;
            default)
                if [[ -v marker_idx["${p}"] ]]; then
                    local raw def
                    _knit_param_default raw "${mangled}" "${p}"
                    def=$(_knit_resolve_default "${raw}")
                    __knit_ret1["${marker_slot[${p}]}"]="${def}"
                    remove["${marker_idx[${p}]}"]=1
                fi
                ;;
            sweep)
                if [[ "${has_domain}" != "true" ]]; then
                    knit_fatal "Cannot @sweep '%s': it has no declared domain. Give it a value on the line, or declare it with --domain '{...}'." "${p}"
                fi
                local -a dvals
                _knit_sweep_enumerate_domain dvals "${mangled}" "${p}"
                local joined
                printf -v joined '%s\n' "${dvals[@]}"
                joined="${joined%$'\n'}"
                if [[ -v marker_idx["${p}"] ]]; then
                    local mi="${marker_idx[${p}]}"
                    __knit_ret2["${mi}"]="literal ${marker_slot[${p}]} ${p}"
                    __knit_ret3["${mi}"]="${joined}"
                else
                    local hyph
                    _knit_str_underscores_to_hyphens hyph "${p}"
                    __knit_ret1+=("--${hyph}" "__SWEEP__")
                    local newslot=$(( ${#__knit_ret1[@]} - 1 ))
                    __knit_ret2+=("literal ${newslot} ${p}")
                    __knit_ret3+=("${joined}")
                fi
                ;;
        esac
    done

    # Drop the @default axes now pinned into the template.
    if [[ ${#remove[@]} -gt 0 ]]; then
        local -a kept_axes=() kept_vals=()
        for ((i=0; i<${#__knit_ret2[@]}; i++)); do
            [[ -v remove["${i}"] ]] && continue
            kept_axes+=("${__knit_ret2[i]}")
            kept_vals+=("${__knit_ret3[i]}")
        done
        __knit_ret2=("${kept_axes[@]}")
        __knit_ret3=("${kept_vals[@]}")
    fi

    # Any marker left unresolved names a parameter the target does not have.
    for ((i=0; i<${#__knit_ret2[@]}; i++)); do
        read -r kind slot name <<< "${__knit_ret2[i]}"
        if [[ "${kind}" == "sweep" || "${kind}" == "default" ]]; then
            knit_fatal "@%s references '%s', which is not a parameter of the downstream target '%s'." \
                "${kind}" "${name}" "${mangled}"
        fi
    done
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
