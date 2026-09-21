#!/bin/bash

## @file metadata.sh

# ------------------------------------------------------------------------------
# Registration of the metadata command.
# ------------------------------------------------------------------------------
knit_register metadata knit_empty "Access metadata about the experiment."
_knit_is_builtin
knit_done

# ------------------------------------------------------------------------------
# Store a key/value pair in the metadata table of the experiment.
# ------------------------------------------------------------------------------
knit_register "metadata:store" _knit_metadata_store "Store a key/value pair of metadata."
_knit_is_builtin
knit_with_required "key:string" "Key."
knit_with_required "value:string" "Value."
knit_with_flag "force" "Overwrite the value if the key already exists."
# ------------------------------------------------------------------------------
# @fn _knit_metadata_store()
#
# Store a key/value pair in the metadata table. When the --force flag is set,
# an existing value for the same key is overwritten; otherwise storing a
# duplicate key fails on the table's uniqueness constraint.
# ------------------------------------------------------------------------------
_knit_metadata_store() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local key
    local value
    local force
    key=$(knit_get_parameter "key" "$@")
    value=$(knit_get_parameter "value" "$@")
    force=$(knit_get_parameter "force" "$@") || force="false"
    local verb="INSERT"
    [[ "${force}" == "true" ]] && verb="INSERT OR REPLACE"
    local esc_key esc_value
    _knit_sql_escape esc_key "${key}"
    _knit_sql_escape esc_value "${value}"
    _knit_sqlite3_write "${verb} INTO metadata (key, value) VALUES ('${esc_key}', '${esc_value}');"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_metadata_get()
#
# Look up the value associated with a key in the metadata table and store it in
# the caller-named variable (empty when the key is absent). This is the
# nameref-returning counterpart of the `metadata load` command body, for
# internal hot-path callers that would otherwise capture the value with a
# forking command substitution.
#
# @param[out] __knit_ret Name of the variable to hold the value.
# @param[in] key Metadata key to look up.
# ------------------------------------------------------------------------------
_knit_metadata_get() {
    local -n __knit_ret=$1
    local key="$2"
    local esc_key
    _knit_sql_escape esc_key "${key}"
    __knit_ret=$(_knit_sqlite3 "SELECT value FROM metadata WHERE key = '${esc_key}';")
}

# ------------------------------------------------------------------------------
# Load the value associated with a key from the metadata table.
# ------------------------------------------------------------------------------
knit_register "metadata:load" _knit_metadata_load "Load the value associated with a key in the metadata."
_knit_is_builtin
knit_with_required "key:string" "Key."
# ------------------------------------------------------------------------------
# @fn _knit_metadata_load()
#
# Load the value associated with a key from the metadata table (the CLI command
# body; prints the value to stdout). Internal callers should use
# _knit_metadata_get instead to avoid a command substitution.
# ------------------------------------------------------------------------------
_knit_metadata_load() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local key value
    key=$(knit_get_parameter "key" "$@")
    _knit_metadata_get value "${key}"
    printf '%s\n' "${value}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_metadata_is_json()
#
# Return success when the given text is valid JSON, using Knit's jq.
#
# @param[in] value Text to test.
# ------------------------------------------------------------------------------
_knit_metadata_is_json() {
    printf '%s' "$1" | _knit_jq -e . >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# @fn _knit_metadata_render_value()
#
# Render a metadata value for a single line of at most a given width. The rules,
# in order:
#   - a value with no newline that fits in the budget is shown as-is;
#   - otherwise a value that is valid JSON is shown as "<json>";
#   - otherwise a value whose first line fits is shown as that first line
#     followed by "...";
#   - otherwise the first line is truncated to fit and followed by "...".
#
# @param[out] __knit_ret Name of the variable to hold the rendered value.
# @param[in] value The raw metadata value.
# @param[in] avail Number of columns available for the value.
# ------------------------------------------------------------------------------
_knit_metadata_render_value() {
    local -n __knit_ret=$1
    local value="$2"
    local avail="$3"
    local ellipsis="..."
    local multiline=0 first="${value}"
    if [[ "${value}" == *$'\n'* ]]; then
        multiline=1
        first="${value%%$'\n'*}"
    fi
    # A single line that fits is shown verbatim.
    if (( multiline == 0 )) && (( ${#value} <= avail )); then
        __knit_ret="${value}"
        return 0
    fi
    # Structured values collapse to a placeholder.
    if _knit_metadata_is_json "${value}"; then
        __knit_ret="<json>"
        return 0
    fi
    # Fall back to the (possibly truncated) first line plus an ellipsis.
    local budget=$(( avail - ${#ellipsis} ))
    (( budget < 0 )) && budget=0
    if (( ${#first} <= budget )); then
        __knit_ret="${first}${ellipsis}"
    else
        __knit_ret="${first:0:budget}${ellipsis}"
    fi
}

# ------------------------------------------------------------------------------
# Show the content of the metadata table of the experiment.
# ------------------------------------------------------------------------------
knit_register "metadata:show" _knit_metadata_show "Show all the stored metadata."
_knit_is_builtin
# ------------------------------------------------------------------------------
# @fn _knit_metadata_show()
#
# Show the content of the metadata table, one key/value pair per line. Values
# are rendered by _knit_metadata_render_value so that long or multi-line values
# do not take over the screen.
# ------------------------------------------------------------------------------
_knit_metadata_show() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local keys
    keys=$(_knit_sqlite3 "SELECT key FROM metadata ORDER BY key;")
    [[ -z "${keys}" ]] && return 0
    # Terminal width, falling back to 80 columns when there is no tty.
    local cols
    read -r _ cols < <(stty size 2>/dev/null </dev/tty || echo "24 80")
    [[ "${cols}" =~ ^[0-9]+$ ]] && (( cols > 0 )) || cols=80
    # Width of the key column: the longest key plus a two-space gap.
    local key maxkey=0
    while IFS= read -r key; do
        (( ${#key} > maxkey )) && maxkey=${#key}
    done <<< "${keys}"
    local keycol=$(( maxkey + 2 ))
    local avail=$(( cols - keycol ))
    (( avail < 1 )) && avail=1
    local value rendered
    while IFS= read -r key; do
        _knit_metadata_get value "${key}"
        _knit_metadata_render_value rendered "${value}" "${avail}"
        printf '%-*s%s\n' "${keycol}" "${key}" "${rendered}"
    done <<< "${keys}"
}
knit_done
