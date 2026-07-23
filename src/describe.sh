#!/bin/bash

## @file describe.sh

# ------------------------------------------------------------------------------
# @var _KNIT_DESCRIBE_FILTERS
#
# Boolean filter state for the current "describe" invocation, populated by
# _knit_describe from the parsed flags and consulted by the model/traversal
# layer so every formatter inherits the same filtering. Keys: "exclude_builtins",
# "no_input_params", "no_output_params", "include_hidden", and "recursive"; each
# value is "true" or "false". A missing key defaults to "false", so the default
# (no filtering) also applies when the traversal is exercised directly.
# ------------------------------------------------------------------------------
declare -gA _KNIT_DESCRIBE_FILTERS

# ------------------------------------------------------------------------------
# @var _KNIT_DESCRIBE_ONLY
#
# Set of mangled command names selected by "--only" for the current "describe"
# invocation. Empty means no selection was given, in which case every (visible)
# command is described.
# ------------------------------------------------------------------------------
declare -gA _KNIT_DESCRIBE_ONLY

# ------------------------------------------------------------------------------
# @var _KNIT_DESCRIBE_JSON_NL
#
# Inter-entry newline the JSON builders insert inside objects and arrays. Its
# default (a newline) produces pretty-printed JSON; _knit_describe_json_compact
# shadows it with the empty string to emit single-line compact JSON without a
# second minify pass.
# ------------------------------------------------------------------------------
declare -g _KNIT_DESCRIBE_JSON_NL
_KNIT_DESCRIBE_JSON_NL=$'\n'

# ------------------------------------------------------------------------------
# @var _KNIT_DESCRIBE_JSON_CS
#
# Insignificant space the JSON builders insert after each ":" and inline ",".
# Defaults to a single space (pretty); shadowed with the empty string by
# _knit_describe_json_compact for compact output.
# ------------------------------------------------------------------------------
declare -g _KNIT_DESCRIBE_JSON_CS
_KNIT_DESCRIBE_JSON_CS=' '

# ------------------------------------------------------------------------------
# @var _KNIT_DESCRIBE_JSON_IND
#
# One level of indentation for the JSON builders. Defaults to two spaces
# (pretty); shadowed with the empty string by _knit_describe_json_compact so all
# indentation collapses for compact output.
# ------------------------------------------------------------------------------
declare -g _KNIT_DESCRIBE_JSON_IND
_KNIT_DESCRIBE_JSON_IND='  '

# ------------------------------------------------------------------------------
# @fn _knit_describe_json_escape()
#
# Escape a string so it can be embedded inside a JSON string literal, without any
# external dependency (no jq), so "describe" works on a fresh checkout before
# bootstrap. Backslashes and double quotes are backslash-escaped; newlines, CR,
# and tabs become their short escapes; any remaining control character becomes a
# "\uXXXX" escape. The surrounding quotes are NOT added (see
# _knit_describe_json_str).
#
# @param __knit_ret Name of the variable to hold the escaped string.
# @param string String to escape.
# ------------------------------------------------------------------------------
_knit_describe_json_escape() {
    local -n __knit_ret=$1
    local __s="$2"
    __s="${__s//\\/\\\\}"
    __s="${__s//\"/\\\"}"
    __s="${__s//$'\n'/\\n}"
    __s="${__s//$'\r'/\\r}"
    __s="${__s//$'\t'/\\t}"
    # After the substitutions above the short-escaped characters are ordinary
    # two-character sequences, so any control character still present needs the
    # generic "\uXXXX" form. Only walk the string when one is actually there.
    if [[ "${__s}" == *[[:cntrl:]]* ]]; then
        local __out='' __i __ch
        for (( __i=0; __i<${#__s}; __i++ )); do
            __ch="${__s:__i:1}"
            if [[ "${__ch}" == [[:cntrl:]] ]]; then
                printf -v __ch '\\u%04x' "'${__ch}"
            fi
            __out+="${__ch}"
        done
        __s="${__out}"
    fi
    __knit_ret="${__s}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_json_str()
#
# Return a value as a quoted, escaped JSON string literal.
#
# @param __knit_ret Name of the variable to hold the JSON string literal.
# @param string Value to render.
# ------------------------------------------------------------------------------
_knit_describe_json_str() {
    local -n __knit_ret=$1
    local __esc
    _knit_describe_json_escape __esc "$2"
    __knit_ret="\"${__esc}\""
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_emit_object()
#
# Emit a JSON object from a list of already-rendered entries. The opening brace
# is printed inline (the caller positions it, e.g. right after a "key": prefix);
# each entry must already carry its own indentation; the closing brace is printed
# at the given indent. An empty entry list yields "{}".
#
# @param indent    Indentation string for the closing brace.
# @param ...entries Pre-rendered "key": value fragments (indented).
# ------------------------------------------------------------------------------
_knit_describe_emit_object() {
    local indent="$1"
    shift
    if (( $# == 0 )); then
        printf '{}'
        return
    fi
    printf '{%s' "${_KNIT_DESCRIBE_JSON_NL}"
    local n=$# i=0 e
    for e in "$@"; do
        i=$(( i + 1 ))
        printf '%s' "${e}"
        (( i < n )) && printf ','
        printf '%s' "${_KNIT_DESCRIBE_JSON_NL}"
    done
    printf '%s}' "${indent}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_emit_array()
#
# Emit a JSON array from a list of already-rendered elements. The opening bracket
# is printed inline; each element must already carry its own indentation; the
# closing bracket is printed at the given indent. An empty element list yields
# "[]".
#
# @param indent      Indentation string for the closing bracket.
# @param ...elements Pre-rendered array elements (indented).
# ------------------------------------------------------------------------------
_knit_describe_emit_array() {
    local indent="$1"
    shift
    if (( $# == 0 )); then
        printf '[]'
        return
    fi
    printf '[%s' "${_KNIT_DESCRIBE_JSON_NL}"
    local n=$# i=0 e
    for e in "$@"; do
        i=$(( i + 1 ))
        printf '%s' "${e}"
        (( i < n )) && printf ','
        printf '%s' "${_KNIT_DESCRIBE_JSON_NL}"
    done
    printf '%s]' "${indent}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_children()
#
# Return the mangled names of the direct children of a command as an array, in
# registration (declaration) order. The parent is given as a mangled name, or
# the empty string to list the top-level (root) commands. This reads the command
# tree adjacency built at registration time (_KNIT_ROOT_COMMANDS and the
# per-command "_KNIT_CMD_<cmd>_subcommands" arrays), so it is fork-free and needs
# no per-invocation build/teardown.
#
# @param __knit_ret Name of the array variable to populate (nameref output).
# @param parent Mangled parent command name, or "" for top-level commands.
# ------------------------------------------------------------------------------
_knit_describe_children() {
    # The output nameref is an indexed array. The sibling describe helpers all use
    # the conventional "__knit_ret" name for scalar (string) outputs; reusing it
    # here would make shellcheck infer "__knit_ret" as an array file-wide and warn
    # on every scalar use, so this one array output gets a distinct reserved name.
    # shellcheck disable=SC2178 # nameref to indexed array
    local -n __knit_ret_children=$1; shift
    local parent="$1"
    if [[ -z "${parent}" ]]; then
        __knit_ret_children=("${_KNIT_ROOT_COMMANDS[@]}")
    else
        # shellcheck disable=SC2178 # nameref to indexed array
        local -n __knit_children_ref="_KNIT_CMD_${parent}_subcommands"
        __knit_ret_children=("${__knit_children_ref[@]}")
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_command_kind()
#
# Print the structural kind of a command, derived from its registration:
# "wrapper" (knit_register_wrapper), "job" (a child of "submit"), "app" (a child
# of "run"), "setup" (a child of "setup"), or "command" otherwise.
#
# @param __knit_ret Name of the variable to hold the command kind.
# @param cmd Mangled command name.
# ------------------------------------------------------------------------------
_knit_describe_command_kind() {
    local -n __knit_ret=$1
    local __cmd="$2"
    if _knit_command_is_wrapper "${__cmd}"; then
        __knit_ret='wrapper'
        return
    fi
    local __parent
    _knit_command_get_parents __parent "${__cmd}"
    case "${__parent}" in
        submit) __knit_ret='job' ;;
        run)    __knit_ret='app' ;;
        setup)  __knit_ret='setup' ;;
        *)      __knit_ret='command' ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_filter_on()
#
# Return success if the named boolean filter is enabled for the current
# invocation. Unknown or unset keys are treated as disabled.
#
# @param name Filter key (see _KNIT_DESCRIBE_FILTERS).
# ------------------------------------------------------------------------------
_knit_describe_filter_on() {
    [[ "${_KNIT_DESCRIBE_FILTERS[$1]:-false}" == "true" ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_visible()
#
# Return success if a command passes the hidden/builtin filters, independent of
# any "--only" selection: hidden commands are dropped unless "--include-hidden"
# is set, and builtin commands are dropped when "--exclude-builtins" is set.
#
# @param cmd Mangled command name.
# ------------------------------------------------------------------------------
_knit_describe_visible() {
    local cmd="$1"
    if ! _knit_describe_filter_on include_hidden; then
        local hidden_var="_KNIT_CMD_${cmd}_is_hidden"
        [[ "${!hidden_var}" == "true" ]] && return 1
    fi
    if _knit_describe_filter_on exclude_builtins; then
        _knit_command_is_builtin "${cmd}" && return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_should_emit()
#
# Decide whether a command appears in the filtered command tree. A command is
# emitted when it is visible (passes the hidden/builtin filters) and either:
#   - no "--only" selection is active (every visible command is selected), or
#   - it is itself selected by "--only", or
#   - an ancestor is selected and "--recursive" is set, or
#   - it has a descendant that is itself emitted (so it is kept as a container
#     that preserves the path down to a selected command).
#
# @param cmd          Mangled command name.
# @param sel_ancestor "true" if an ancestor of the command is in the "--only"
#                     selection, "false" otherwise.
# ------------------------------------------------------------------------------
_knit_describe_should_emit() {
    local cmd="$1"
    local sel_ancestor="$2"
    _knit_describe_visible "${cmd}" || return 1
    # No selection: every visible command is described.
    (( ${#_KNIT_DESCRIBE_ONLY[@]} == 0 )) && return 0
    _knit_set_find _KNIT_DESCRIBE_ONLY "${cmd}" && return 0
    if [[ "${sel_ancestor}" == "true" ]] && _knit_describe_filter_on recursive; then
        return 0
    fi
    # Not selected: keep the command only as a container for a selected
    # descendant. The command is not in the selection here, so the ancestor flag
    # passed down is unchanged.
    local -a __children
    _knit_describe_children __children "${cmd}"
    local c
    for c in "${__children[@]}"; do
        _knit_describe_should_emit "${c}" "${sel_ancestor}" && return 0
    done
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_implementation()
#
# Print a command's implementation — its registered function body as produced by
# "declare -f" — when "--include-implementation" is active and the command is a
# user (non-builtin) command. Prints nothing otherwise: without the flag no body
# is emitted, and a builtin's body is knit implementation detail that is never
# dumped. Every formatter consults this so the rule is applied in one place.
#
# @param cmd Mangled command name.
# ------------------------------------------------------------------------------
_knit_describe_implementation() {
    local cmd="$1"
    _knit_describe_filter_on include_implementation || return
    _knit_command_is_builtin "${cmd}" && return
    local fn_var="_KNIT_CMD_${cmd}_function"
    local fn="${!fn_var:-}"
    [[ -z "${fn}" ]] && return
    declare -f "${fn}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_enum_values_json()
#
# Return the values of an enum as an inline JSON array of strings (sorted for a
# stable order).
#
# @param __knit_ret Name of the variable to hold the JSON array.
# @param name Enum type name.
# ------------------------------------------------------------------------------
_knit_describe_enum_values_json() {
    local -n __knit_ret=$1
    local __name="$2"
    local __out='[' __first=1 __v __s
    local -a __vals
    _knit_set_array __vals "_KNIT_ENUM_${__name}"
    for __v in "${__vals[@]}"; do
        (( __first )) || __out+=",${_KNIT_DESCRIBE_JSON_CS}"
        _knit_describe_json_str __s "${__v}"
        __out+="${__s}"
        __first=0
    done
    __out+=']'
    __knit_ret="${__out}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_json_param()
#
# Render one input parameter as a JSON object (array element: the leading indent
# is included). The rendered fields depend on the group: "required" has no
# default, "optional" adds a raw default, and "flags" are always boolean with no
# default or enum. An enum-typed parameter inlines its allowed values, and a
# "--when" constraint is included when present.
#
# @param cmd    Mangled command name.
# @param group  Parameter group ("required", "optional", or "flags").
# @param param  Normalized parameter name.
# @param indent Indentation of the object's opening brace.
# ------------------------------------------------------------------------------
_knit_describe_json_param() {
    local cmd="$1"
    local group="$2"
    local param="$3"
    local indent="$4"
    local inner="${indent}${_KNIT_DESCRIBE_JSON_IND}"
    local cs="${_KNIT_DESCRIBE_JSON_CS}"
    local dname type desc
    _knit_str_underscores_to_hyphens dname "${param}"
    _knit_param_description desc "${cmd}" "${param}"
    if [[ "${group}" == "flags" ]]; then
        type="boolean"
    else
        _knit_param_type type "${cmd}" "${param}"
    fi
    local entries=() s e
    _knit_describe_json_str s "${dname}"
    printf -v e '%s"name":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    _knit_describe_json_str s "${type}"
    printf -v e '%s"type":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    if [[ "${group}" != "flags" ]]; then
        local resolved
        if _knit_type_resolve_alias resolved "${type}" \
            && [[ -v _KNIT_ENUMS["${resolved}"] ]]; then
            _knit_describe_enum_values_json s "${resolved}"
            printf -v e '%s"enum":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
        fi
    fi
    if [[ "${group}" == "optional" ]]; then
        local dflt
        _knit_param_default dflt "${cmd}" "${param}"
        _knit_describe_json_str s "${dflt}"
        printf -v e '%s"default":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    fi
    _knit_describe_json_str s "${desc}"
    printf -v e '%s"description":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    local when_raw_var="_KNIT_CMD_${cmd}_2_${param}_when_raw"
    if [[ -v "${when_raw_var}" ]]; then
        _knit_describe_json_str s "${!when_raw_var}"
        printf -v e '%s"when":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    fi
    printf '%s' "${indent}"
    _knit_describe_emit_object "${indent}" "${entries[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_json_params()
#
# Render a command's "parameters" object (required, optional, flags arrays, and
# the extra description). Printed inline (object value: no leading indent).
#
# @param cmd    Mangled command name.
# @param indent Indentation of the object's opening brace.
# ------------------------------------------------------------------------------
_knit_describe_json_params() {
    local cmd="$1"
    local indent="$2"
    local inner="${indent}${_KNIT_DESCRIBE_JSON_IND}"
    local elem="${inner}${_KNIT_DESCRIBE_JSON_IND}"
    local cs="${_KNIT_DESCRIBE_JSON_CS}"
    local p
    local req=() opt=() flg=()
    local -a __items
    _knit_set_array __items "_KNIT_CMD_${cmd}_required"
    for p in "${__items[@]}"; do
        req+=("$(_knit_describe_json_param "${cmd}" required "${p}" "${elem}")")
    done
    _knit_set_array __items "_KNIT_CMD_${cmd}_optional"
    for p in "${__items[@]}"; do
        opt+=("$(_knit_describe_json_param "${cmd}" optional "${p}" "${elem}")")
    done
    _knit_set_array __items "_KNIT_CMD_${cmd}_flags"
    for p in "${__items[@]}"; do
        flg+=("$(_knit_describe_json_param "${cmd}" flags "${p}" "${elem}")")
    done
    local entries=()
    entries+=("$(printf '%s"required":%s' "${inner}" "${cs}"; _knit_describe_emit_array "${inner}" "${req[@]}")")
    entries+=("$(printf '%s"optional":%s' "${inner}" "${cs}"; _knit_describe_emit_array "${inner}" "${opt[@]}")")
    entries+=("$(printf '%s"flags":%s' "${inner}" "${cs}"; _knit_describe_emit_array "${inner}" "${flg[@]}")")
    local extra_var="_KNIT_CMD_${cmd}_extra"
    local extra_json='null'
    if [[ -n "${!extra_var}" ]]; then
        _knit_describe_json_str extra_json "${!extra_var}"
    fi
    entries+=("$(printf '%s"extra":%s%s' "${inner}" "${cs}" "${extra_json}")")
    _knit_describe_emit_object "${indent}" "${entries[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_json_output()
#
# Render one output as a JSON object (array element: leading indent included).
#
# @param cmd    Mangled command name.
# @param output Normalized output name.
# @param indent Indentation of the object's opening brace.
# ------------------------------------------------------------------------------
_knit_describe_json_output() {
    local cmd="$1"
    local output="$2"
    local indent="$3"
    local inner="${indent}${_KNIT_DESCRIBE_JSON_IND}"
    local cs="${_KNIT_DESCRIBE_JSON_CS}"
    local dname type dflt desc
    _knit_str_underscores_to_hyphens dname "${output}"
    _knit_output_type type "${cmd}" "${output}"
    _knit_output_default dflt "${cmd}" "${output}"
    _knit_output_description desc "${cmd}" "${output}"
    local entries=() s e
    _knit_describe_json_str s "${dname}"
    printf -v e '%s"name":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    _knit_describe_json_str s "${type}"
    printf -v e '%s"type":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    _knit_describe_json_str s "${dflt}"
    printf -v e '%s"default":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    _knit_describe_json_str s "${desc}"
    printf -v e '%s"description":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    printf '%s' "${indent}"
    _knit_describe_emit_object "${indent}" "${entries[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_json_outputs()
#
# Render a command's "outputs" array. Printed inline (object value: no leading
# indent).
#
# @param cmd    Mangled command name.
# @param indent Indentation of the array's opening bracket.
# ------------------------------------------------------------------------------
_knit_describe_json_outputs() {
    local cmd="$1"
    local indent="$2"
    local elem="${indent}${_KNIT_DESCRIBE_JSON_IND}"
    local items=() o
    local -a __items
    _knit_set_array __items "_KNIT_CMD_${cmd}_outputs"
    for o in "${__items[@]}"; do
        items+=("$(_knit_describe_json_output "${cmd}" "${o}" "${elem}")")
    done
    _knit_describe_emit_array "${indent}" "${items[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_json_command()
#
# Render a single command (and, recursively, its subcommands) as a JSON object.
# The object is an array element, so its leading indent is included. Subcommands
# are pruned by the active filters (hidden/builtin/"--only"), matching the
# top-level command list.
#
# @param cmd          Mangled command name.
# @param indent       Indentation of the object's opening brace.
# @param sel_ancestor "true" if an ancestor of the command is in the "--only"
#                     selection.
# ------------------------------------------------------------------------------
_knit_describe_json_command() {
    local cmd="$1"
    local indent="$2"
    local sel_ancestor="$3"
    local inner="${indent}${_KNIT_DESCRIBE_JSON_IND}"
    local cs="${_KNIT_DESCRIBE_JSON_CS}"
    local demangled
    demangled=$(_knit_command_demangle "${cmd}")
    local -a segs
    IFS=':' read -r -a segs <<< "${demangled}"
    local name="${segs[-1]}"

    local path_json='[' i s
    for (( i=0; i<${#segs[@]}; i++ )); do
        (( i )) && path_json+=",${cs}"
        _knit_describe_json_str s "${segs[i]}"
        path_json+="${s}"
    done
    path_json+=']'

    local desc_var="_KNIT_CMD_${cmd}_description"
    local kind
    _knit_describe_command_kind kind "${cmd}"
    local builtin=false hidden=false
    _knit_command_is_builtin "${cmd}" && builtin=true
    local hidden_var="_KNIT_CMD_${cmd}_is_hidden"
    [[ "${!hidden_var}" == "true" ]] && hidden=true
    local dispatch_var="_KNIT_CMD_${cmd}_dispatch"
    local dispatch_json='null'
    [[ -n "${!dispatch_var}" ]] && _knit_describe_json_str dispatch_json "${!dispatch_var}"
    local prov_var="_KNIT_CMD_${cmd}_provenance"
    local prov="${!prov_var}"
    [[ -z "${prov}" ]] && prov='default'
    local table_var="_KNIT_CMD_${cmd}_table"
    local table_json='null'
    [[ -n "${!table_var:-}" ]] && _knit_describe_json_str table_json "${!table_var}"

    local child_sel_ancestor="${sel_ancestor}"
    _knit_set_find _KNIT_DESCRIBE_ONLY "${cmd}" && child_sel_ancestor="true"
    local -a __children
    _knit_describe_children __children "${cmd}"
    local subs=() c
    for c in "${__children[@]}"; do
        _knit_describe_should_emit "${c}" "${child_sel_ancestor}" || continue
        subs+=("$(_knit_describe_json_command "${c}" "${inner}${_KNIT_DESCRIBE_JSON_IND}" "${child_sel_ancestor}")")
    done

    local entries=() e
    _knit_describe_json_str s "${name}"
    printf -v e '%s"name":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    printf -v e '%s"path":%s%s' "${inner}" "${cs}" "${path_json}"; entries+=("${e}")
    _knit_describe_json_str s "${!desc_var}"
    printf -v e '%s"description":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    _knit_describe_json_str s "${kind}"
    printf -v e '%s"kind":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    printf -v e '%s"builtin":%s%s' "${inner}" "${cs}" "${builtin}"; entries+=("${e}")
    printf -v e '%s"hidden":%s%s' "${inner}" "${cs}" "${hidden}"; entries+=("${e}")
    printf -v e '%s"dispatcher":%s%s' "${inner}" "${cs}" "${dispatch_json}"; entries+=("${e}")
    _knit_describe_json_str s "${prov}"
    printf -v e '%s"provenance":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    printf -v e '%s"table":%s%s' "${inner}" "${cs}" "${table_json}"; entries+=("${e}")
    if ! _knit_describe_filter_on no_input_params; then
        entries+=("$(printf '%s"parameters":%s' "${inner}" "${cs}"; _knit_describe_json_params "${cmd}" "${inner}")")
    fi
    if ! _knit_describe_filter_on no_output_params; then
        entries+=("$(printf '%s"outputs":%s' "${inner}" "${cs}"; _knit_describe_json_outputs "${cmd}" "${inner}")")
    fi
    local impl
    impl=$(_knit_describe_implementation "${cmd}")
    if [[ -n "${impl}" ]]; then
        _knit_describe_json_str s "${impl}"
        printf -v e '%s"implementation":%s%s' "${inner}" "${cs}" "${s}"; entries+=("${e}")
    fi
    entries+=("$(printf '%s"subcommands":%s' "${inner}" "${cs}"; _knit_describe_emit_array "${inner}" "${subs[@]}")")

    printf '%s' "${indent}"
    _knit_describe_emit_object "${indent}" "${entries[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_json_enums()
#
# Render the top-level "enums" object: every user-defined (non-builtin) enum
# mapped to its values. Printed inline (object value: no leading indent).
#
# @param indent Indentation of the object's opening brace.
# ------------------------------------------------------------------------------
_knit_describe_json_enums() {
    local indent="$1"
    local inner="${indent}${_KNIT_DESCRIBE_JSON_IND}"
    local entries=() name s vals e
    local -a __enums
    _knit_set_array __enums _KNIT_ENUMS
    for name in "${__enums[@]}"; do
        _knit_set_find _KNIT_BUILTIN_ENUMS "${name}" && continue
        _knit_describe_json_str s "${name}"
        _knit_describe_enum_values_json vals "${name}"
        printf -v e '%s%s:%s%s' "${inner}" "${s}" "${_KNIT_DESCRIBE_JSON_CS}" "${vals}"; entries+=("${e}")
    done
    _knit_describe_emit_object "${indent}" "${entries[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_json()
#
# Emit the complete description of the experiment as a JSON document: knit
# version, experiment (script) name, format version, the full command tree
# (top-level commands with nested subcommands, hidden commands excluded), and the
# map of user-defined enums.
# ------------------------------------------------------------------------------
_knit_describe_json() {
    local ind="${_KNIT_DESCRIBE_JSON_IND}"
    local cs="${_KNIT_DESCRIBE_JSON_CS}"
    local -a __children
    _knit_describe_children __children ""
    local roots=() c
    for c in "${__children[@]}"; do
        _knit_describe_should_emit "${c}" "false" || continue
        roots+=("$(_knit_describe_json_command "${c}" "${ind}${ind}" "false")")
    done

    local entries=() s e
    _knit_describe_json_str s "${KNIT_VERSION}"
    printf -v e '%s"knit_version":%s%s' "${ind}" "${cs}" "${s}"; entries+=("${e}")
    _knit_describe_json_str s "${KNIT_SCRIPT_NAME}"
    printf -v e '%s"experiment":%s%s' "${ind}" "${cs}" "${s}"; entries+=("${e}")
    entries+=("$(printf '%s"format_version":%s1' "${ind}" "${cs}")")
    entries+=("$(printf '%s"commands":%s' "${ind}" "${cs}"; _knit_describe_emit_array "${ind}" "${roots[@]}")")
    entries+=("$(printf '%s"enums":%s' "${ind}" "${cs}"; _knit_describe_json_enums "${ind}")")
    _knit_describe_emit_object "" "${entries[@]}"
    printf '\n'
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_json_compact()
#
# Emit the JSON description as a single compact line (no indentation, no
# inter-entry newlines, and no spaces after ":" or ","). It shadows the JSON
# builders' whitespace separators (_KNIT_DESCRIBE_JSON_NL / _CS / _IND) with the
# empty string for the duration of one _knit_describe_json call, so the compact
# form is produced directly by the same builder tree — no second minify pass.
# The locals are visible to the builders (and their command-substitution
# subshells) through bash dynamic scoping, and are restored automatically on
# return.
# ------------------------------------------------------------------------------
_knit_describe_json_compact() {
    # These shadow the module-scoped separators consulted by the JSON builders
    # and their nested command substitutions; shellcheck sees them assigned but
    # not read within this function, hence the disable.
    # shellcheck disable=SC2034 # read by the builders via dynamic scoping
    local _KNIT_DESCRIBE_JSON_NL='' _KNIT_DESCRIBE_JSON_CS='' _KNIT_DESCRIBE_JSON_IND=''
    _knit_describe_json
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_yaml_needs_quote()
#
# Return success when a single-line string value must be double-quoted to survive
# a YAML round-trip as a string: leaving it as a plain scalar would either coerce
# it to another type (number, boolean, null) or be syntactically unsafe.
# Double-quoting an already-safe value is harmless, so the predicate errs toward
# quoting. Multi-line values are handled separately as block scalars.
#
# @param value String value to test.
# ------------------------------------------------------------------------------
_knit_describe_yaml_needs_quote() {
    local v="$1"
    # Empty, or leading/trailing whitespace, or an embedded tab.
    [[ -z "${v}" ]] && return 0
    [[ "${v}" == [[:space:]]* || "${v}" == *[[:space:]] ]] && return 0
    [[ "${v}" == *$'\t'* ]] && return 0
    # Numeric- or version-looking (a leading digit, or a sign/dot then a digit).
    [[ "${v}" == [0-9]* || "${v}" == [-+.][0-9]* ]] && return 0
    # YAML boolean / null tokens (case-insensitive), as resolved by common parsers.
    case "${v,,}" in
        true|false|yes|no|on|off|null|'~') return 0 ;;
    esac
    # A leading indicator character is unsafe in plain style.
    local indicators='-?:,[]{}#&*!|>%@'
    indicators+='`'
    indicators+="'"
    indicators+='"'
    [[ "${indicators}" == *"${v:0:1}"* ]] && return 0
    # A "colon+space", a trailing colon, or a "space+hash" breaks a plain scalar.
    [[ "${v}" == *": "* || "${v}" == *: || "${v}" == *" #"* ]] && return 0
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_yaml_scalar()
#
# Render a string value as a YAML scalar to follow "key: ". A multi-line value
# becomes a literal block scalar ("|-") whose lines are indented by cont_indent;
# a single-line value that would be coerced or is unsafe as a plain scalar is
# double-quoted (reusing the JSON escaper, whose escapes YAML's double-quoted
# style shares); anything else is emitted verbatim.
#
# @param __knit_ret  Name of the variable to hold the rendered scalar.
# @param value       String value to render.
# @param cont_indent Indentation prepended to each line of a block scalar.
# ------------------------------------------------------------------------------
_knit_describe_yaml_scalar() {
    local -n __knit_ret=$1
    local __value="$2"
    local __cont_indent="$3"
    if [[ "${__value}" == *$'\n'* ]]; then
        local __out='|-' __line
        while IFS= read -r __line || [[ -n "${__line}" ]]; do
            __out+=$'\n'"${__cont_indent}${__line}"
        done <<< "${__value}"
        __knit_ret="${__out}"
        return
    fi
    if _knit_describe_yaml_needs_quote "${__value}"; then
        local __esc
        _knit_describe_json_escape __esc "${__value}"
        __knit_ret="\"${__esc}\""
    else
        __knit_ret="${__value}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_yaml_flow_seq()
#
# Print a YAML flow sequence ("[a, b, c]") of scalar values, each double-quoted
# when it would be unsafe or coerced as a plain flow scalar (the plain-scalar
# rules plus the flow indicators , [ ] { }). An empty list yields "[]".
#
# @param __knit_ret Name of the variable to hold the flow sequence.
# @param ...values Scalar values.
# ------------------------------------------------------------------------------
_knit_describe_yaml_flow_seq() {
    local -n __knit_ret=$1; shift
    local __out='[' __first=1 __v __esc
    for __v in "$@"; do
        (( __first )) || __out+=', '
        __first=0
        if _knit_describe_yaml_needs_quote "${__v}" \
            || [[ "${__v}" == *,* || "${__v}" == *"["* || "${__v}" == *"]"* \
               || "${__v}" == *"{"* || "${__v}" == *"}"* ]]; then
            _knit_describe_json_escape __esc "${__v}"
            __out+="\"${__esc}\""
        else
            __out+="${__v}"
        fi
    done
    __out+=']'
    __knit_ret="${__out}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_yaml_param()
#
# Render one input parameter as a YAML block-sequence element (the first key
# carries the "- " indicator at item_indent). Mirrors the JSON parameter object:
# an enum type inlines its allowed values, "optional" carries a raw default, flags
# are boolean with no default, and a "--when" constraint is included when present.
#
# @param cmd         Mangled command name.
# @param group       Parameter group ("required", "optional", or "flags").
# @param param       Normalized parameter name.
# @param item_indent Indentation of the "- " sequence indicator.
# ------------------------------------------------------------------------------
_knit_describe_yaml_param() {
    local cmd="$1" group="$2" param="$3" item_indent="$4"
    local key="${item_indent}  "
    local cont="${key}  "
    local dname type desc sc
    _knit_str_underscores_to_hyphens dname "${param}"
    _knit_param_description desc "${cmd}" "${param}"
    if [[ "${group}" == "flags" ]]; then
        type="boolean"
    else
        _knit_param_type type "${cmd}" "${param}"
    fi
    _knit_describe_yaml_scalar sc "${dname}" "${cont}"
    printf '%s- name: %s\n' "${item_indent}" "${sc}"
    _knit_describe_yaml_scalar sc "${type}" "${cont}"
    printf '%stype: %s\n' "${key}" "${sc}"
    if [[ "${group}" != "flags" ]]; then
        local resolved
        if _knit_type_resolve_alias resolved "${type}" \
            && [[ -v _KNIT_ENUMS["${resolved}"] ]]; then
            local vals fs
            _knit_set_array vals "_KNIT_ENUM_${resolved}"
            _knit_describe_yaml_flow_seq fs "${vals[@]}"
            printf '%senum: %s\n' "${key}" "${fs}"
        fi
    fi
    if [[ "${group}" == "optional" ]]; then
        local dflt
        _knit_param_default dflt "${cmd}" "${param}"
        _knit_describe_yaml_scalar sc "${dflt}" "${cont}"
        printf '%sdefault: %s\n' "${key}" "${sc}"
    fi
    _knit_describe_yaml_scalar sc "${desc}" "${cont}"
    printf '%sdescription: %s\n' "${key}" "${sc}"
    local when_raw_var="_KNIT_CMD_${cmd}_2_${param}_when_raw"
    if [[ -v "${when_raw_var}" ]]; then
        _knit_describe_yaml_scalar sc "${!when_raw_var}" "${cont}"
        printf '%swhen: %s\n' "${key}" "${sc}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_yaml_params()
#
# Render a command's "parameters:" mapping body: the required/optional/flags
# sequences (each "[]" when empty) and the "extra" scalar (or null), with the
# group keys at keys_indent. The "parameters:" key line itself is printed by the
# caller.
#
# @param cmd         Mangled command name.
# @param keys_indent Indentation of the required/optional/flags keys.
# ------------------------------------------------------------------------------
_knit_describe_yaml_params() {
    local cmd="$1" keys_indent="$2"
    local item="${keys_indent}  "
    local grp p
    local -a names
    for grp in required optional flags; do
        _knit_set_array names "_KNIT_CMD_${cmd}_${grp}"
        if (( ${#names[@]} == 0 )); then
            printf '%s%s: []\n' "${keys_indent}" "${grp}"
        else
            printf '%s%s:\n' "${keys_indent}" "${grp}"
            for p in "${names[@]}"; do
                _knit_describe_yaml_param "${cmd}" "${grp}" "${p}" "${item}"
            done
        fi
    done
    local extra_var="_KNIT_CMD_${cmd}_extra"
    if [[ -n "${!extra_var}" ]]; then
        local sc
        _knit_describe_yaml_scalar sc "${!extra_var}" "${keys_indent}  "
        printf '%sextra: %s\n' "${keys_indent}" "${sc}"
    else
        printf '%sextra: null\n' "${keys_indent}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_yaml_output()
#
# Render one output as a YAML block-sequence element (the first key carries the
# "- " indicator at item_indent).
#
# @param cmd         Mangled command name.
# @param output      Normalized output name.
# @param item_indent Indentation of the "- " sequence indicator.
# ------------------------------------------------------------------------------
_knit_describe_yaml_output() {
    local cmd="$1" output="$2" item_indent="$3"
    local key="${item_indent}  "
    local cont="${key}  "
    local dname type dflt desc sc
    _knit_str_underscores_to_hyphens dname "${output}"
    _knit_output_type type "${cmd}" "${output}"
    _knit_output_default dflt "${cmd}" "${output}"
    _knit_output_description desc "${cmd}" "${output}"
    _knit_describe_yaml_scalar sc "${dname}" "${cont}"
    printf '%s- name: %s\n' "${item_indent}" "${sc}"
    _knit_describe_yaml_scalar sc "${type}" "${cont}"
    printf '%stype: %s\n' "${key}" "${sc}"
    _knit_describe_yaml_scalar sc "${dflt}" "${cont}"
    printf '%sdefault: %s\n' "${key}" "${sc}"
    _knit_describe_yaml_scalar sc "${desc}" "${cont}"
    printf '%sdescription: %s\n' "${key}" "${sc}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_yaml_command()
#
# Render a single command (and, recursively, its subcommands) as a YAML
# block-sequence element (the first key carries the "- " indicator at
# item_indent). Subcommands are pruned by the active filters
# (hidden/builtin/"--only"), matching the top-level command list.
#
# @param cmd          Mangled command name.
# @param item_indent  Indentation of the "- " sequence indicator.
# @param sel_ancestor "true" if an ancestor of the command is in the "--only"
#                     selection.
# ------------------------------------------------------------------------------
_knit_describe_yaml_command() {
    local cmd="$1" item_indent="$2" sel_ancestor="$3"
    local key="${item_indent}  "
    local cont="${key}  "
    local demangled
    demangled=$(_knit_command_demangle "${cmd}")
    local -a segs
    IFS=':' read -r -a segs <<< "${demangled}"
    local name="${segs[-1]}"

    local desc_var="_KNIT_CMD_${cmd}_description"
    local kind sc fs
    _knit_describe_command_kind kind "${cmd}"
    local builtin=false hidden=false
    _knit_command_is_builtin "${cmd}" && builtin=true
    local hidden_var="_KNIT_CMD_${cmd}_is_hidden"
    [[ "${!hidden_var}" == "true" ]] && hidden=true
    local dispatch_var="_KNIT_CMD_${cmd}_dispatch"
    local prov_var="_KNIT_CMD_${cmd}_provenance"
    local prov="${!prov_var}"
    [[ -z "${prov}" ]] && prov='default'
    local table_var="_KNIT_CMD_${cmd}_table"

    _knit_describe_yaml_scalar sc "${name}" "${cont}"
    printf '%s- name: %s\n' "${item_indent}" "${sc}"
    _knit_describe_yaml_flow_seq fs "${segs[@]}"
    printf '%spath: %s\n' "${key}" "${fs}"
    _knit_describe_yaml_scalar sc "${!desc_var}" "${cont}"
    printf '%sdescription: %s\n' "${key}" "${sc}"
    _knit_describe_yaml_scalar sc "${kind}" "${cont}"
    printf '%skind: %s\n' "${key}" "${sc}"
    printf '%sbuiltin: %s\n' "${key}" "${builtin}"
    printf '%shidden: %s\n' "${key}" "${hidden}"
    if [[ -n "${!dispatch_var}" ]]; then
        _knit_describe_yaml_scalar sc "${!dispatch_var}" "${cont}"
        printf '%sdispatcher: %s\n' "${key}" "${sc}"
    else
        printf '%sdispatcher: null\n' "${key}"
    fi
    _knit_describe_yaml_scalar sc "${prov}" "${cont}"
    printf '%sprovenance: %s\n' "${key}" "${sc}"
    if [[ -n "${!table_var:-}" ]]; then
        _knit_describe_yaml_scalar sc "${!table_var}" "${cont}"
        printf '%stable: %s\n' "${key}" "${sc}"
    else
        printf '%stable: null\n' "${key}"
    fi
    if ! _knit_describe_filter_on no_input_params; then
        printf '%sparameters:\n' "${key}"
        _knit_describe_yaml_params "${cmd}" "${cont}"
    fi
    if ! _knit_describe_filter_on no_output_params; then
        local -a onames
        local o
        _knit_set_array onames "_KNIT_CMD_${cmd}_outputs"
        if (( ${#onames[@]} == 0 )); then
            printf '%soutputs: []\n' "${key}"
        else
            printf '%soutputs:\n' "${key}"
            for o in "${onames[@]}"; do
                _knit_describe_yaml_output "${cmd}" "${o}" "${cont}"
            done
        fi
    fi
    local impl
    impl=$(_knit_describe_implementation "${cmd}")
    if [[ -n "${impl}" ]]; then
        _knit_describe_yaml_scalar sc "${impl}" "${cont}"
        printf '%simplementation: %s\n' "${key}" "${sc}"
    fi

    local child_sel_ancestor="${sel_ancestor}"
    _knit_set_find _KNIT_DESCRIBE_ONLY "${cmd}" && child_sel_ancestor="true"
    local -a __children
    _knit_describe_children __children "${cmd}"
    local -a subs=()
    local c
    for c in "${__children[@]}"; do
        _knit_describe_should_emit "${c}" "${child_sel_ancestor}" || continue
        subs+=("${c}")
    done
    if (( ${#subs[@]} == 0 )); then
        printf '%ssubcommands: []\n' "${key}"
    else
        printf '%ssubcommands:\n' "${key}"
        for c in "${subs[@]}"; do
            _knit_describe_yaml_command "${c}" "${cont}" "${child_sel_ancestor}"
        done
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_yaml_enums()
#
# Render the top-level "enums:" mapping: every user-defined (non-builtin) enum
# mapped to its values as a flow sequence. Yields "enums: {}" when there are none.
# ------------------------------------------------------------------------------
_knit_describe_yaml_enums() {
    local -a names=()
    local name
    local -a __enums
    _knit_set_array __enums _KNIT_ENUMS
    for name in "${__enums[@]}"; do
        _knit_set_find _KNIT_BUILTIN_ENUMS "${name}" && continue
        names+=("${name}")
    done
    if (( ${#names[@]} == 0 )); then
        printf 'enums: {}\n'
        return
    fi
    printf 'enums:\n'
    local sc fs
    local -a vals
    for name in "${names[@]}"; do
        _knit_set_array vals "_KNIT_ENUM_${name}"
        _knit_describe_yaml_scalar sc "${name}" '    '
        _knit_describe_yaml_flow_seq fs "${vals[@]}"
        printf '  %s: %s\n' "${sc}" "${fs}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_yaml()
#
# Emit the complete description of the experiment as a YAML document, serializing
# the identical model as _knit_describe_json (same keys, nesting, and field
# semantics): knit version, experiment (script) name, format version, the filtered
# command tree, and the map of user-defined enums.
# ------------------------------------------------------------------------------
_knit_describe_yaml() {
    local sc
    _knit_describe_yaml_scalar sc "${KNIT_VERSION}" '  '
    printf 'knit_version: %s\n' "${sc}"
    _knit_describe_yaml_scalar sc "${KNIT_SCRIPT_NAME}" '  '
    printf 'experiment: %s\n' "${sc}"
    printf 'format_version: 1\n'
    local -a __children
    _knit_describe_children __children ""
    local -a roots=()
    local c
    for c in "${__children[@]}"; do
        _knit_describe_should_emit "${c}" "false" || continue
        roots+=("${c}")
    done
    if (( ${#roots[@]} == 0 )); then
        printf 'commands: []\n'
    else
        printf 'commands:\n'
        for c in "${roots[@]}"; do
            _knit_describe_yaml_command "${c}" '  ' "false"
        done
    fi
    _knit_describe_yaml_enums
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_stdout_is_terminal()
#
# Return success when standard output is a terminal. Factored into its own
# function so tests can stub it to force color on or off deterministically.
# ------------------------------------------------------------------------------
_knit_describe_stdout_is_terminal() {
    [[ -t 1 ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_default_heading()
#
# Print a title or section header for the human-readable format. With color it
# is rendered bold and underlined on its own line; without color it is followed
# by an "---" hrule of matching width (the style "--help" uses).
#
# @param text      Header text.
# @param use_color "true" to emit ANSI styling, "false" for an hrule.
# @param indent    Leading indentation (defaults to none).
# ------------------------------------------------------------------------------
_knit_describe_default_heading() {
    local text="$1"
    local use_color="$2"
    local indent="${3:-}"
    if [[ "${use_color}" == "true" ]]; then
        printf '%s%s%s%s\n' "${indent}" \
            "${_KNIT_COLORS[bold]}${_KNIT_COLORS[underline]}" \
            "${text}" "${_KNIT_COLORS[reset]}"
    else
        local hrule
        printf -v hrule '%*s' "${#text}" ''
        hrule="${hrule// /-}"
        printf '%s%s\n%s%s\n' "${indent}" "${text}" "${indent}" "${hrule}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_enum_constraint()
#
# Return a "one of: a, b, c" constraint string for an enum-typed parameter, or
# the empty string when the parameter's type is not an enum. Values are sorted to
# match the other formatters.
#
# @param __knit_ret Name of the variable to hold the constraint string.
# @param cmd   Mangled command name.
# @param param Normalized parameter name.
# ------------------------------------------------------------------------------
_knit_describe_enum_constraint() {
    local -n __knit_ret=$1
    local __cmd="$2"
    local __param="$3"
    local __type __resolved
    _knit_param_type __type "${__cmd}" "${__param}"
    __knit_ret=""
    if _knit_type_resolve_alias __resolved "${__type}" \
        && [[ -v _KNIT_ENUMS["${__resolved}"] ]]; then
        local __out='' __v
        local -a __vals
        _knit_set_array __vals "_KNIT_ENUM_${__resolved}"
        for __v in "${__vals[@]}"; do
            [[ -n "${__out}" ]] && __out+=', '
            __out+="${__v}"
        done
        __knit_ret="one of: ${__out}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_default_options()
#
# Print a command's "Options" section for the human-readable format, mirroring
# the "--help" layout: a header, the "--help" entry, then required, optional
# (with "default: '…'") and flag parameters, column-aligned, each annotated with
# its enum constraint and "when:" clause when present.
#
# @param cmd       Mangled command name.
# @param use_color "true" to emit ANSI styling in the header.
# @param indent    Leading indentation for the section header (defaults to none);
#                  entries are indented two further spaces.
# ------------------------------------------------------------------------------
_knit_describe_default_options() {
    local cmd="$1"
    local use_color="$2"
    local indent="${3:-}"
    local cind="${indent}  "
    local req_var="_KNIT_CMD_${cmd}_required"
    local opt_var="_KNIT_CMD_${cmd}_optional"
    local flg_var="_KNIT_CMD_${cmd}_flags"

    local max=4 opt opt2 len
    local -a __items
    _knit_set_array __items "${req_var}"
    for opt in "${__items[@]}"; do
        _knit_str_underscores_to_hyphens opt2 "${opt}"
        opt2="--${opt2} <value>"
        len=${#opt2}; (( len > max )) && max=${len}
    done
    _knit_set_array __items "${opt_var}"
    for opt in "${__items[@]}"; do
        _knit_str_underscores_to_hyphens opt2 "${opt}"
        opt2="--${opt2} <value>"
        len=${#opt2}; (( len > max )) && max=${len}
    done
    _knit_set_array __items "${flg_var}"
    for opt in "${__items[@]}"; do
        _knit_str_underscores_to_hyphens opt2 "${opt}"
        opt2="--${opt2}"
        len=${#opt2}; (( len > max )) && max=${len}
    done

    _knit_describe_default_heading "Options" "${use_color}" "${indent}"
    printf '%s%-*s  %s\n' "${cind}" "${max}" "--help" \
        "Print this help message and exit."

    local desc dflt when_var ann cons
    _knit_set_array __items "${req_var}"
    for opt in "${__items[@]}"; do
        _knit_param_description desc "${cmd}" "${opt}"
        _knit_str_underscores_to_hyphens opt2 "${opt}"
        opt2="--${opt2} <value>"
        when_var="_KNIT_CMD_${cmd}_2_${opt}_when_raw"
        ann="required"
        _knit_describe_enum_constraint cons "${cmd}" "${opt}"
        [[ -n "${cons}" ]] && ann+=", ${cons}"
        [[ -v "${when_var}" ]] && ann+=", when: ${!when_var}"
        printf '%s%-*s  [%s] %s\n' "${cind}" "${max}" "${opt2}" "${ann}" "${desc}"
    done
    _knit_set_array __items "${opt_var}"
    for opt in "${__items[@]}"; do
        _knit_param_description desc "${cmd}" "${opt}"
        _knit_param_default dflt "${cmd}" "${opt}"
        _knit_str_underscores_to_hyphens opt2 "${opt}"
        opt2="--${opt2} <value>"
        when_var="_KNIT_CMD_${cmd}_2_${opt}_when_raw"
        ann="default: '${dflt}'"
        _knit_describe_enum_constraint cons "${cmd}" "${opt}"
        [[ -n "${cons}" ]] && ann+=", ${cons}"
        [[ -v "${when_var}" ]] && ann+=", when: ${!when_var}"
        printf '%s%-*s  [%s] %s\n' "${cind}" "${max}" "${opt2}" "${ann}" "${desc}"
    done
    _knit_set_array __items "${flg_var}"
    for opt in "${__items[@]}"; do
        _knit_param_description desc "${cmd}" "${opt}"
        _knit_str_underscores_to_hyphens opt2 "${opt}"
        opt2="--${opt2}"
        when_var="_KNIT_CMD_${cmd}_2_${opt}_when_raw"
        ann="flag"
        [[ -v "${when_var}" ]] && ann+=", when: ${!when_var}"
        printf '%s%-*s  [%s] %s\n' "${cind}" "${max}" "${opt2}" "${ann}" "${desc}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_default_outputs()
#
# Print a command's "Outputs" section for the human-readable format (name, then
# "[type, default: '…'] description"). Prints nothing when the command declares
# no outputs.
#
# @param cmd       Mangled command name.
# @param use_color "true" to emit ANSI styling in the header.
# @param indent    Leading indentation for the section header (defaults to none);
#                  entries are indented two further spaces.
# ------------------------------------------------------------------------------
_knit_describe_default_outputs() {
    local cmd="$1"
    local use_color="$2"
    local indent="${3:-}"
    local cind="${indent}  "
    local outs_var="_KNIT_CMD_${cmd}_outputs"

    local max=0 o o2 len
    local -a __items
    _knit_set_array __items "${outs_var}"
    for o in "${__items[@]}"; do
        _knit_str_underscores_to_hyphens o2 "${o}"
        len=${#o2}; (( len > max )) && max=${len}
    done

    _knit_describe_default_heading "Outputs" "${use_color}" "${indent}"
    local type dflt desc
    for o in "${__items[@]}"; do
        _knit_str_underscores_to_hyphens o2 "${o}"
        _knit_output_type type "${cmd}" "${o}"
        _knit_output_default dflt "${cmd}" "${o}"
        _knit_output_description desc "${cmd}" "${o}"
        printf '%s%-*s  [%s, default: '\''%s'\''] %s\n' \
            "${cind}" "${max}" "${o2}" "${type}" "${dflt}" "${desc}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_default_command()
#
# Print one command as a titled block for the human-readable format, then recurse
# (flat, depth-first) into its emitted subcommands so each command is its own
# block titled by its full space-separated name. The Options and Outputs sections
# honor the "--no-input-params" / "--no-output-params" filters, an "Extra" section
# is printed when the command declares post-"--" arguments, and an "Implementation"
# section (the function body) is printed for a user command when
# "--include-implementation" is set.
#
# @param cmd          Mangled command name.
# @param use_color    "true" to emit ANSI styling.
# @param sel_ancestor "true" if an ancestor of the command is in the "--only"
#                     selection.
# ------------------------------------------------------------------------------
_knit_describe_default_command() {
    local cmd="$1"
    local use_color="$2"
    local sel_ancestor="$3"
    local display kind tag
    display=$(_knit_command_with_space "${cmd}")
    _knit_describe_command_kind kind "${cmd}"
    if _knit_command_is_builtin "${cmd}"; then tag="builtin"; else tag="user"; fi
    local desc_var="_KNIT_CMD_${cmd}_description"

    # Command titles stay at column 0 (the format is flat; depth is conveyed by
    # the full name), but each command's sections are indented beneath it.
    local sec="  "

    _knit_describe_default_heading "${display}" "${use_color}"
    printf '%s[%s, %s]  %s\n' "${sec}" "${kind}" "${tag}" "${!desc_var}"

    if ! _knit_describe_filter_on no_input_params; then
        printf '\n'
        _knit_describe_default_options "${cmd}" "${use_color}" "${sec}"
    fi

    local -a __outs
    _knit_set_array __outs "_KNIT_CMD_${cmd}_outputs"
    if ! _knit_describe_filter_on no_output_params && (( ${#__outs[@]} )); then
        printf '\n'
        _knit_describe_default_outputs "${cmd}" "${use_color}" "${sec}"
    fi

    local extra_var="_KNIT_CMD_${cmd}_extra"
    if [[ -n "${!extra_var}" ]]; then
        printf '\n'
        _knit_describe_default_heading "Extra" "${use_color}" "${sec}"
        printf '%s  %s\n' "${sec}" "${!extra_var}"
    fi

    local impl
    impl=$(_knit_describe_implementation "${cmd}")
    if [[ -n "${impl}" ]]; then
        printf '\n'
        _knit_describe_default_heading "Implementation" "${use_color}" "${sec}"
        local iline
        while IFS= read -r iline || [[ -n "${iline}" ]]; do
            printf '%s  %s\n' "${sec}" "${iline}"
        done <<< "${impl}"
    fi

    local child_sel_ancestor="${sel_ancestor}"
    _knit_set_find _KNIT_DESCRIBE_ONLY "${cmd}" && child_sel_ancestor="true"
    local -a __children
    _knit_describe_children __children "${cmd}"
    local c
    for c in "${__children[@]}"; do
        _knit_describe_should_emit "${c}" "${child_sel_ancestor}" || continue
        printf '\n'
        _knit_describe_default_command "${c}" "${use_color}" "${child_sel_ancestor}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_default()
#
# Emit the human-readable description of the experiment: one titled block per
# command, walked depth-first so a subcommand follows its parent. Color is
# enabled only when stdout is a terminal and "--no-color" is not given.
#
# @param ... Command arguments (expanded by the CLI framework).
# ------------------------------------------------------------------------------
_knit_describe_default() {
    local no_color use_color
    no_color=$(knit_get_parameter no-color "$@") || no_color="false"
    if [[ "${no_color}" != "true" ]] && _knit_describe_stdout_is_terminal; then
        use_color="true"
    else
        use_color="false"
    fi

    local -a __children
    _knit_describe_children __children ""
    local first=1 c
    for c in "${__children[@]}"; do
        _knit_describe_should_emit "${c}" "false" || continue
        (( first )) || printf '\n'
        first=0
        _knit_describe_default_command "${c}" "${use_color}" "false"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_md_cell()
#
# Escape a value so it is safe inside a Markdown table cell: pipes are backslash-
# escaped (they otherwise start a new column) and newlines/carriage returns are
# folded to spaces (a table row must stay on one line).
#
# @param __knit_ret Name of the variable to hold the escaped value.
# @param value Value to escape.
# ------------------------------------------------------------------------------
_knit_describe_md_cell() {
    local -n __knit_ret=$1
    local __v="$2"
    __v="${__v//$'\n'/ }"
    __v="${__v//$'\r'/ }"
    __v="${__v//|/\\|}"
    __knit_ret="${__v}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_md_code()
#
# Render a value as a Markdown inline-code span (escaped for a table cell). An
# empty value yields nothing, so this doubles as the "Default" column renderer:
# a declared value is shown as code and an empty-string default leaves a blank
# cell.
#
# @param __knit_ret Name of the variable to hold the rendered code span.
# @param value Value to render.
# ------------------------------------------------------------------------------
_knit_describe_md_code() {
    local -n __knit_ret=$1
    local __v="$2"
    __knit_ret=""
    [[ -z "${__v}" ]] && return
    local __cell __code
    _knit_describe_md_cell __cell "${__v}"
    # shellcheck disable=SC2016 # backticks are literal Markdown code-span delimiters
    printf -v __code '`%s`' "${__cell}"
    __knit_ret="${__code}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_md_constraints()
#
# Build the "Constraints" column text for a parameter: the enum "one of: …" list
# (when the type is an enum) and the "--when" clause (with the raw expression in
# inline code), joined by "; ". Returns the empty string when the parameter is
# unconstrained.
#
# @param __knit_ret Name of the variable to hold the constraints text.
# @param cmd   Mangled command name.
# @param param Normalized parameter name.
# ------------------------------------------------------------------------------
_knit_describe_md_constraints() {
    local -n __knit_ret=$1
    local __cmd="$2"
    local __param="$3"
    # The accumulator must not be named like any internal local of a helper it
    # passes itself to by name: _knit_describe_enum_constraint has its own
    # "local __out", which would shadow a nameref pointed at a caller "__out".
    local acc __when_var
    _knit_describe_enum_constraint acc "${__cmd}" "${__param}"
    __when_var="_KNIT_CMD_${__cmd}_2_${__param}_when_raw"
    if [[ -v "${__when_var}" ]]; then
        [[ -n "${acc}" ]] && acc+='; '
        acc+="when: \`${!__when_var}\`"
    fi
    __knit_ret="${acc}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_md_params()
#
# Print a command's "#### Parameters" sub-section as a Markdown table (one row per
# required, optional, and flag parameter, in that order; each group sorted), with
# a "Kind" column marking the group. Prints "*None.*" when the command declares no
# parameters. The universal "--help" flag is intentionally omitted.
#
# @param cmd Mangled command name.
# ------------------------------------------------------------------------------
_knit_describe_md_params() {
    local cmd="$1"
    printf '#### Parameters\n\n'
    local -a rows=()
    local p type desc dname cons dcell pdflt row c_name c_type c_cons c_desc
    local -a __items
    _knit_set_array __items "_KNIT_CMD_${cmd}_required"
    for p in "${__items[@]}"; do
        _knit_str_underscores_to_hyphens dname "${p}"
        _knit_param_type type "${cmd}" "${p}"
        _knit_param_description desc "${cmd}" "${p}"
        _knit_describe_md_constraints cons "${cmd}" "${p}"
        [[ -z "${cons}" ]] && cons='—'
        _knit_describe_md_code c_name "${dname}"
        _knit_describe_md_cell c_type "${type}"
        _knit_describe_md_cell c_cons "${cons}"
        _knit_describe_md_cell c_desc "${desc}"
        printf -v row '| %s | required | %s | — | %s | %s |' \
            "${c_name}" "${c_type}" "${c_cons}" "${c_desc}"
        rows+=("${row}")
    done
    _knit_set_array __items "_KNIT_CMD_${cmd}_optional"
    for p in "${__items[@]}"; do
        _knit_str_underscores_to_hyphens dname "${p}"
        _knit_param_type type "${cmd}" "${p}"
        _knit_param_description desc "${cmd}" "${p}"
        _knit_describe_md_constraints cons "${cmd}" "${p}"
        [[ -z "${cons}" ]] && cons='—'
        _knit_param_default pdflt "${cmd}" "${p}"
        _knit_describe_md_code dcell "${pdflt}"
        _knit_describe_md_code c_name "${dname}"
        _knit_describe_md_cell c_type "${type}"
        _knit_describe_md_cell c_cons "${cons}"
        _knit_describe_md_cell c_desc "${desc}"
        printf -v row '| %s | optional | %s | %s | %s | %s |' \
            "${c_name}" "${c_type}" "${dcell}" "${c_cons}" "${c_desc}"
        rows+=("${row}")
    done
    _knit_set_array __items "_KNIT_CMD_${cmd}_flags"
    for p in "${__items[@]}"; do
        _knit_str_underscores_to_hyphens dname "${p}"
        _knit_param_description desc "${cmd}" "${p}"
        _knit_describe_md_constraints cons "${cmd}" "${p}"
        [[ -z "${cons}" ]] && cons='—'
        _knit_describe_md_code c_name "${dname}"
        _knit_describe_md_cell c_cons "${cons}"
        _knit_describe_md_cell c_desc "${desc}"
        printf -v row '| %s | flag | boolean | — | %s | %s |' \
            "${c_name}" "${c_cons}" "${c_desc}"
        rows+=("${row}")
    done

    if (( ${#rows[@]} == 0 )); then
        printf '*None.*\n'
        return
    fi
    printf '| Name | Kind | Type | Default | Constraints | Description |\n'
    printf '|------|------|------|---------|-------------|-------------|\n'
    local r
    for r in "${rows[@]}"; do printf '%s\n' "${r}"; done
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_md_outputs()
#
# Print a command's "#### Outputs" sub-section as a Markdown table (one row per
# output, sorted). Prints "*None.*" when the command declares no outputs.
#
# @param cmd Mangled command name.
# ------------------------------------------------------------------------------
_knit_describe_md_outputs() {
    local cmd="$1"
    printf '#### Outputs\n\n'
    local -a rows=()
    local o dname type dflt desc dcell row c_name c_type c_desc
    local -a __items
    _knit_set_array __items "_KNIT_CMD_${cmd}_outputs"
    for o in "${__items[@]}"; do
        _knit_str_underscores_to_hyphens dname "${o}"
        _knit_output_type type "${cmd}" "${o}"
        _knit_output_default dflt "${cmd}" "${o}"
        _knit_output_description desc "${cmd}" "${o}"
        _knit_describe_md_code dcell "${dflt}"
        _knit_describe_md_code c_name "${dname}"
        _knit_describe_md_cell c_type "${type}"
        _knit_describe_md_cell c_desc "${desc}"
        printf -v row '| %s | %s | %s | %s |' \
            "${c_name}" "${c_type}" "${dcell}" "${c_desc}"
        rows+=("${row}")
    done

    if (( ${#rows[@]} == 0 )); then
        printf '*None.*\n'
        return
    fi
    printf '| Name | Type | Default | Description |\n'
    printf '|------|------|---------|-------------|\n'
    local r
    for r in "${rows[@]}"; do printf '%s\n' "${r}"; done
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_md_command()
#
# Render one command as a "### <full name>" Markdown section (an intro line with
# its kind/builtin note and description, an italic "Extra" line when declared, the
# "#### Parameters" / "#### Outputs" sub-sections honoring the omit flags, and a
# fenced "#### Implementation" block for a user command when
# "--include-implementation" is set), then recurse (flat, depth-first) into its
# emitted subcommands so each command is its own "###" section regardless of depth.
#
# @param cmd          Mangled command name.
# @param sel_ancestor "true" if an ancestor of the command is in the "--only"
#                     selection.
# ------------------------------------------------------------------------------
_knit_describe_md_command() {
    local cmd="$1"
    local sel_ancestor="$2"
    local display kind tag
    display=$(_knit_command_with_space "${cmd}")
    _knit_describe_command_kind kind "${cmd}"
    if _knit_command_is_builtin "${cmd}"; then tag="builtin"; else tag="user"; fi
    local desc_var="_KNIT_CMD_${cmd}_description"

    printf '### %s\n\n' "${display}"
    printf '*%s, %s* — %s\n' "${kind}" "${tag}" "${!desc_var}"

    local extra_var="_KNIT_CMD_${cmd}_extra"
    if [[ -n "${!extra_var}" ]]; then
        printf '\n*Extra: %s*\n' "${!extra_var}"
    fi

    if ! _knit_describe_filter_on no_input_params; then
        printf '\n'
        _knit_describe_md_params "${cmd}"
    fi
    if ! _knit_describe_filter_on no_output_params; then
        printf '\n'
        _knit_describe_md_outputs "${cmd}"
    fi

    local impl
    impl=$(_knit_describe_implementation "${cmd}")
    if [[ -n "${impl}" ]]; then
        # shellcheck disable=SC2016 # backticks are literal Markdown fence delimiters
        printf '\n#### Implementation\n\n```bash\n%s\n```\n' "${impl}"
    fi

    local child_sel_ancestor="${sel_ancestor}"
    _knit_set_find _KNIT_DESCRIBE_ONLY "${cmd}" && child_sel_ancestor="true"
    local -a __children
    _knit_describe_children __children "${cmd}"
    local c
    for c in "${__children[@]}"; do
        _knit_describe_should_emit "${c}" "${child_sel_ancestor}" || continue
        printf '\n'
        _knit_describe_md_command "${c}" "${child_sel_ancestor}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_markdown()
#
# Emit the complete description of the experiment as a single Markdown document: a
# "#" title (the program description, or the script name when unset), a "##
# Commands" wrapper, and one flat "###" section per command (depth-first, so a
# subcommand follows its parent). Depth does not consume heading levels, keeping
# the scheme within Markdown's six-level limit. Enum values are inlined in each
# parameter's Constraints column rather than a separate section.
# ------------------------------------------------------------------------------
_knit_describe_markdown() {
    local title_var="_KNIT_CMD___main___description"
    local title="${!title_var}"
    if [[ -z "${title}" || "${title}" == *knit_set_program_description* ]]; then
        title="${KNIT_SCRIPT_NAME}"
    fi
    printf '# %s\n\n' "${title}"
    printf '## Commands\n'
    local -a __children
    _knit_describe_children __children ""
    local c
    for c in "${__children[@]}"; do
        _knit_describe_should_emit "${c}" "false" || continue
        printf '\n'
        _knit_describe_md_command "${c}" "false"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_read_filters()
#
# Populate the module-level filter state (_KNIT_DESCRIBE_FILTERS and
# _KNIT_DESCRIBE_ONLY) from the current invocation's arguments, so the
# model/traversal layer applies the requested filtering. Called by _knit_describe
# before any formatter runs.
#
# @param ... Command arguments (expanded by the CLI framework).
# ------------------------------------------------------------------------------
_knit_describe_read_filters() {
    _KNIT_DESCRIBE_FILTERS=()
    _KNIT_DESCRIBE_ONLY=()
    local flag
    for flag in exclude_builtins no_input_params no_output_params \
                include_hidden recursive include_implementation; do
        _KNIT_DESCRIBE_FILTERS["${flag}"]=$( \
            knit_get_parameter "${flag//_/-}" "$@" || printf 'false')
    done
    local only
    only=$(knit_get_parameter only "$@") || only=""
    if [[ -n "${only}" ]]; then
        local -a selected=()
        IFS=',' read -r -a selected <<< "${only}"
        local name
        for name in "${selected[@]}"; do
            [[ -z "${name}" ]] && continue
            _knit_set_add _KNIT_DESCRIBE_ONLY "$(_knit_command_mangle "${name}")"
        done
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_emit()
#
# Emit the description in the requested format to standard output. Split out from
# _knit_describe so the caller can redirect the whole document to a file for
# "--output" without duplicating the format dispatch. "--compact" selects the
# single-line JSON variant and applies only to the "json" format.
#
# @param format  Output format ("default", "json", "yaml", or "markdown").
# @param compact "true" to emit compact single-line JSON (json format only).
# @param ...     Command arguments (expanded by the CLI framework).
# ------------------------------------------------------------------------------
_knit_describe_emit() {
    local format="$1"
    local compact="$2"
    shift 2
    case "${format}" in
        default)
            _knit_describe_default "$@"
            ;;
        json)
            if [[ "${compact}" == "true" ]]; then
                _knit_describe_json_compact
            else
                _knit_describe_json
            fi
            ;;
        yaml)
            _knit_describe_yaml
            ;;
        markdown)
            _knit_describe_markdown
            ;;
        *)
            knit_fatal "Unknown describe format '${format}'."
            ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_describe()
#
# Body of the "describe" command: read the requested filters and --format, then
# emit the description in that format. With "--output <file>" the document is
# written to that file instead of standard output (which also disables the
# default format's auto-color, since the destination is not a terminal).
#
# @param ... Command arguments (expanded by the CLI framework).
# ------------------------------------------------------------------------------
_knit_describe() {
    local format output compact
    format=$(knit_get_parameter format "$@") || format="default"
    output=$(knit_get_parameter output "$@") || output=""
    compact=$(knit_get_parameter compact "$@") || compact="false"
    if [[ "${compact}" == "true" && "${format}" != "json" ]]; then
        knit_warning "The --compact flag only applies to --format json; ignoring it."
    fi
    _knit_describe_read_filters "$@"
    if [[ -n "${output}" ]]; then
        _knit_describe_emit "${format}" "${compact}" "$@" > "${output}"
    else
        _knit_describe_emit "${format}" "${compact}" "$@"
    fi
}

knit_define_enum "describe_format" \
    "default" "json" "yaml" "markdown"
_knit_is_builtin

knit_register _knit_describe "describe" \
    "Describe all declared commands and their parameters."
_knit_is_builtin
knit_without_provenance
knit_with_optional "format:describe_format" "default" \
    "Output format: default, json, yaml, or markdown."
knit_with_flag "compact" \
    "Emit single-line JSON with no insignificant whitespace (only applies to --format json)."
knit_with_flag "no-color" \
    "Disable ANSI color in the default format (auto-enabled only on a terminal)." \
    --when '.format == "default"'
knit_with_flag "exclude-builtins" \
    "Omit framework builtin commands; show only user-declared commands."
knit_with_flag "no-input-params" \
    "Omit each command's input parameters."
knit_with_flag "no-output-params" \
    "Omit each command's outputs."
knit_with_optional "only:string" "" \
    "Comma-separated commands/subcommands to describe (colon form, e.g. \"a,b:c\")."
knit_with_flag "recursive" \
    "With --only, also include the selected commands' subcommands."
knit_with_flag "include-hidden" \
    "Include hidden and framework-private commands (excluded by default)."
knit_with_flag "include-implementation" \
    "Include each user command's function body (builtin bodies are never shown)."
knit_with_optional "output:path" "" \
    "Write the description to this file instead of standard output."
knit_done
