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
# @fn _knit_describe_json_escape()
#
# Escape a string so it can be embedded inside a JSON string literal, without any
# external dependency (no jq), so "describe" works on a fresh checkout before
# bootstrap. Backslashes and double quotes are backslash-escaped; newlines, CR,
# and tabs become their short escapes; any remaining control character becomes a
# "\uXXXX" escape. The surrounding quotes are NOT added (see
# _knit_describe_json_str).
#
# @param string String to escape.
# ------------------------------------------------------------------------------
_knit_describe_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    # After the substitutions above the short-escaped characters are ordinary
    # two-character sequences, so any control character still present needs the
    # generic "\uXXXX" form. Only walk the string when one is actually there.
    if [[ "${s}" == *[[:cntrl:]]* ]]; then
        local out='' i ch
        for (( i=0; i<${#s}; i++ )); do
            ch="${s:i:1}"
            if [[ "${ch}" == [[:cntrl:]] ]]; then
                printf -v ch '\\u%04x' "'${ch}"
            fi
            out+="${ch}"
        done
        s="${out}"
    fi
    printf '%s' "${s}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_json_str()
#
# Print a value as a quoted, escaped JSON string literal.
#
# @param string Value to render.
# ------------------------------------------------------------------------------
_knit_describe_json_str() {
    printf '"%s"' "$(_knit_describe_json_escape "$1")"
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
    printf '{\n'
    local n=$# i=0 e
    for e in "$@"; do
        i=$(( i + 1 ))
        printf '%s' "${e}"
        (( i < n )) && printf ','
        printf '\n'
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
    printf '[\n'
    local n=$# i=0 e
    for e in "$@"; do
        i=$(( i + 1 ))
        printf '%s' "${e}"
        (( i < n )) && printf ','
        printf '\n'
    done
    printf '%s]' "${indent}"
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_children()
#
# Print the mangled names of the direct children of a command, sorted for a
# stable order. The parent is given as a mangled name, or the empty string to
# list the top-level (root) commands.
#
# @param parent Mangled parent command name, or "" for top-level commands.
# ------------------------------------------------------------------------------
_knit_describe_children() {
    local parent="$1"
    local c p
    while IFS= read -r c; do
        p=$(_knit_command_get_parents "${c}")
        if [[ "${p}" == "${parent}" ]]; then
            printf '%s\n' "${c}"
        fi
    done < <(_knit_set_iter _KNIT_COMMANDS | sort)
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_command_kind()
#
# Print the structural kind of a command, derived from its registration:
# "wrapper" (knit_register_wrapper), "job" (a child of "submit"), "app" (a child
# of "run"), "setup" (a child of "setup"), or "command" otherwise.
#
# @param cmd Mangled command name.
# ------------------------------------------------------------------------------
_knit_describe_command_kind() {
    local cmd="$1"
    if _knit_command_is_wrapper "${cmd}"; then
        printf 'wrapper'
        return
    fi
    local parent
    parent=$(_knit_command_get_parents "${cmd}")
    case "${parent}" in
        submit) printf 'job' ;;
        run)    printf 'app' ;;
        setup)  printf 'setup' ;;
        *)      printf 'command' ;;
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
    local c
    while IFS= read -r c; do
        _knit_describe_should_emit "${c}" "${sel_ancestor}" && return 0
    done < <(_knit_describe_children "${cmd}")
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_enum_values_json()
#
# Print the values of an enum as an inline JSON array of strings (sorted for a
# stable order).
#
# @param name Enum type name.
# ------------------------------------------------------------------------------
_knit_describe_enum_values_json() {
    local name="$1"
    local out='[' first=1 v
    while IFS= read -r v; do
        (( first )) || out+=', '
        out+="$(_knit_describe_json_str "${v}")"
        first=0
    done < <(knit_enum_values "${name}" | sort)
    out+=']'
    printf '%s' "${out}"
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
    local inner="${indent}  "
    local dname type desc
    dname=$(_knit_str_underscores_to_hyphens "${param}")
    desc=$(_knit_param_description "${cmd}" "${param}")
    if [[ "${group}" == "flags" ]]; then
        type="boolean"
    else
        type=$(_knit_param_type "${cmd}" "${param}")
    fi
    local entries=()
    entries+=("$(printf '%s"name": %s' "${inner}" "$(_knit_describe_json_str "${dname}")")")
    entries+=("$(printf '%s"type": %s' "${inner}" "$(_knit_describe_json_str "${type}")")")
    if [[ "${group}" != "flags" ]]; then
        local resolved
        if resolved=$(_knit_type_resolve_alias "${type}") \
            && [[ -v _KNIT_ENUMS["${resolved}"] ]]; then
            entries+=("$(printf '%s"enum": %s' "${inner}" "$(_knit_describe_enum_values_json "${resolved}")")")
        fi
    fi
    if [[ "${group}" == "optional" ]]; then
        local dflt
        dflt=$(_knit_param_default "${cmd}" "${param}")
        entries+=("$(printf '%s"default": %s' "${inner}" "$(_knit_describe_json_str "${dflt}")")")
    fi
    entries+=("$(printf '%s"description": %s' "${inner}" "$(_knit_describe_json_str "${desc}")")")
    local when_raw_var="_KNIT_CMD_${cmd}_2_${param}_when_raw"
    if [[ -v "${when_raw_var}" ]]; then
        entries+=("$(printf '%s"when": %s' "${inner}" "$(_knit_describe_json_str "${!when_raw_var}")")")
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
    local inner="${indent}  "
    local elem="${inner}  "
    local p
    local req=() opt=() flg=()
    while IFS= read -r p; do
        req+=("$(_knit_describe_json_param "${cmd}" required "${p}" "${elem}")")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_required" | sort)
    while IFS= read -r p; do
        opt+=("$(_knit_describe_json_param "${cmd}" optional "${p}" "${elem}")")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_optional" | sort)
    while IFS= read -r p; do
        flg+=("$(_knit_describe_json_param "${cmd}" flags "${p}" "${elem}")")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_flags" | sort)
    local entries=()
    entries+=("$(printf '%s"required": ' "${inner}"; _knit_describe_emit_array "${inner}" "${req[@]}")")
    entries+=("$(printf '%s"optional": ' "${inner}"; _knit_describe_emit_array "${inner}" "${opt[@]}")")
    entries+=("$(printf '%s"flags": ' "${inner}"; _knit_describe_emit_array "${inner}" "${flg[@]}")")
    local extra_var="_KNIT_CMD_${cmd}_extra"
    local extra_json='null'
    if [[ -n "${!extra_var}" ]]; then
        extra_json="$(_knit_describe_json_str "${!extra_var}")"
    fi
    entries+=("$(printf '%s"extra": %s' "${inner}" "${extra_json}")")
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
    local inner="${indent}  "
    local dname type dflt desc
    dname=$(_knit_str_underscores_to_hyphens "${output}")
    type=$(_knit_output_type "${cmd}" "${output}")
    dflt=$(_knit_output_default "${cmd}" "${output}")
    desc=$(_knit_output_description "${cmd}" "${output}")
    local entries=()
    entries+=("$(printf '%s"name": %s' "${inner}" "$(_knit_describe_json_str "${dname}")")")
    entries+=("$(printf '%s"type": %s' "${inner}" "$(_knit_describe_json_str "${type}")")")
    entries+=("$(printf '%s"default": %s' "${inner}" "$(_knit_describe_json_str "${dflt}")")")
    entries+=("$(printf '%s"description": %s' "${inner}" "$(_knit_describe_json_str "${desc}")")")
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
    local elem="${indent}  "
    local items=() o
    while IFS= read -r o; do
        items+=("$(_knit_describe_json_output "${cmd}" "${o}" "${elem}")")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_outputs" | sort)
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
    local inner="${indent}  "
    local demangled
    demangled=$(_knit_command_demangle "${cmd}")
    local -a segs
    IFS=':' read -r -a segs <<< "${demangled}"
    local name="${segs[-1]}"

    local path_json='[' i
    for (( i=0; i<${#segs[@]}; i++ )); do
        (( i )) && path_json+=', '
        path_json+="$(_knit_describe_json_str "${segs[i]}")"
    done
    path_json+=']'

    local desc_var="_KNIT_CMD_${cmd}_description"
    local kind
    kind=$(_knit_describe_command_kind "${cmd}")
    local builtin=false hidden=false
    _knit_command_is_builtin "${cmd}" && builtin=true
    local hidden_var="_KNIT_CMD_${cmd}_is_hidden"
    [[ "${!hidden_var}" == "true" ]] && hidden=true
    local dispatch_var="_KNIT_CMD_${cmd}_dispatch"
    local dispatch_json='null'
    [[ -n "${!dispatch_var}" ]] && dispatch_json="$(_knit_describe_json_str "${!dispatch_var}")"
    local prov_var="_KNIT_CMD_${cmd}_provenance"
    local prov="${!prov_var}"
    [[ -z "${prov}" ]] && prov='default'
    local table_var="_KNIT_CMD_${cmd}_table"
    local table_json='null'
    [[ -n "${!table_var:-}" ]] && table_json="$(_knit_describe_json_str "${!table_var}")"

    local child_sel_ancestor="${sel_ancestor}"
    _knit_set_find _KNIT_DESCRIBE_ONLY "${cmd}" && child_sel_ancestor="true"
    local subs=() c
    while IFS= read -r c; do
        _knit_describe_should_emit "${c}" "${child_sel_ancestor}" || continue
        subs+=("$(_knit_describe_json_command "${c}" "${inner}  " "${child_sel_ancestor}")")
    done < <(_knit_describe_children "${cmd}")

    local entries=()
    entries+=("$(printf '%s"name": %s' "${inner}" "$(_knit_describe_json_str "${name}")")")
    entries+=("$(printf '%s"path": %s' "${inner}" "${path_json}")")
    entries+=("$(printf '%s"description": %s' "${inner}" "$(_knit_describe_json_str "${!desc_var}")")")
    entries+=("$(printf '%s"kind": %s' "${inner}" "$(_knit_describe_json_str "${kind}")")")
    entries+=("$(printf '%s"builtin": %s' "${inner}" "${builtin}")")
    entries+=("$(printf '%s"hidden": %s' "${inner}" "${hidden}")")
    entries+=("$(printf '%s"dispatcher": %s' "${inner}" "${dispatch_json}")")
    entries+=("$(printf '%s"provenance": %s' "${inner}" "$(_knit_describe_json_str "${prov}")")")
    entries+=("$(printf '%s"table": %s' "${inner}" "${table_json}")")
    if ! _knit_describe_filter_on no_input_params; then
        entries+=("$(printf '%s"parameters": ' "${inner}"; _knit_describe_json_params "${cmd}" "${inner}")")
    fi
    if ! _knit_describe_filter_on no_output_params; then
        entries+=("$(printf '%s"outputs": ' "${inner}"; _knit_describe_json_outputs "${cmd}" "${inner}")")
    fi
    entries+=("$(printf '%s"subcommands": ' "${inner}"; _knit_describe_emit_array "${inner}" "${subs[@]}")")

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
    local inner="${indent}  "
    local entries=() name
    while IFS= read -r name; do
        _knit_set_find _KNIT_BUILTIN_ENUMS "${name}" && continue
        entries+=("$(printf '%s%s: %s' "${inner}" \
            "$(_knit_describe_json_str "${name}")" \
            "$(_knit_describe_enum_values_json "${name}")")")
    done < <(_knit_set_iter _KNIT_ENUMS | sort)
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
    local roots=() c
    while IFS= read -r c; do
        _knit_describe_should_emit "${c}" "false" || continue
        roots+=("$(_knit_describe_json_command "${c}" "    " "false")")
    done < <(_knit_describe_children "")

    local entries=()
    entries+=("$(printf '  "knit_version": %s' "$(_knit_describe_json_str "${KNIT_VERSION}")")")
    entries+=("$(printf '  "experiment": %s' "$(_knit_describe_json_str "${KNIT_SCRIPT_NAME}")")")
    entries+=("$(printf '  "format_version": 1')")
    entries+=("$(printf '  "commands": '; _knit_describe_emit_array "  " "${roots[@]}")")
    entries+=("$(printf '  "enums": '; _knit_describe_json_enums "  ")")
    _knit_describe_emit_object "" "${entries[@]}"
    printf '\n'
}

# ------------------------------------------------------------------------------
# @fn _knit_describe_json_minify()
#
# Strip insignificant whitespace (indentation, newlines, and the spaces the
# pretty printer inserts after ":" and ",") from a JSON document, producing a
# single compact line. The scan is string-aware: whitespace is removed only
# outside of string literals, so spaces inside values are preserved and escape
# sequences (\", \\, \uXXXX, …) are copied verbatim. Pure bash, so it keeps the
# no-jq, works-before-bootstrap guarantee of the rest of "describe".
#
# @param json JSON document to compact.
# ------------------------------------------------------------------------------
_knit_describe_json_minify() {
    local s="$1"
    local out='' seg chunk c
    while [[ -n "${s}" ]]; do
        # Outside a string: consume up to the next quote, dropping whitespace.
        seg="${s%%\"*}"
        out+="${seg//[$' \t\n']/}"
        if [[ "${seg}" == "${s}" ]]; then
            break
        fi
        s="${s#"${seg}"}"
        # Copy the string literal verbatim, honoring backslash escapes.
        out+='"'
        s="${s:1}"
        while [[ -n "${s}" ]]; do
            chunk="${s%%[\"\\]*}"
            out+="${chunk}"
            if [[ "${chunk}" == "${s}" ]]; then
                s=''
                break
            fi
            s="${s#"${chunk}"}"
            c="${s:0:1}"
            if [[ "${c}" == $'\\' ]]; then
                out+="${s:0:2}"
                s="${s:2}"
            else
                out+='"'
                s="${s:1}"
                break
            fi
        done
    done
    printf '%s' "${out}"
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
                include_hidden recursive; do
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
# @fn _knit_describe()
#
# Body of the "describe" command: read the requested filters and --format, then
# emit the description in that format. Only "json" and "json-compact" are
# implemented so far.
#
# @param ... Command arguments (expanded by the CLI framework).
# ------------------------------------------------------------------------------
_knit_describe() {
    local format
    format=$(knit_get_parameter format "$@") || format="default"
    _knit_describe_read_filters "$@"
    case "${format}" in
        json)
            _knit_describe_json
            ;;
        json-compact)
            printf '%s\n' "$(_knit_describe_json_minify "$(_knit_describe_json)")"
            ;;
        *)
            knit_fatal "The '${format}' format is not yet implemented (only 'json' and 'json-compact' are available)."
            ;;
    esac
}

knit_define_enum "describe_format" \
    "default" "json" "json-compact" "yaml" "markdown" "html"
_knit_is_builtin

knit_register _knit_describe "describe" \
    "Describe all declared commands and their parameters."
_knit_is_builtin
knit_without_provenance
knit_with_optional "format:describe_format" "default" \
    "Output format: default, json, json-compact, yaml, markdown, or html."
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
knit_done
