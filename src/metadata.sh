#!/bin/bash

## @file metadata.sh

# ------------------------------------------------------------------------------
# @var _KNIT_METADATA_CACHE
#
# In-process read-through cache of metadata key/value pairs. A key is present in
# this map once it has been read (or written) in the current process; a present
# key with an empty value records a key that is absent from the table, so a
# missing key is not re-queried either. The cache is per-process memory only:
# every fresh knit invocation starts empty and reads the current table on first
# access, so there is no cross-process staleness. _knit_metadata_store drops the
# affected key to keep the cache honest after a write.
# ------------------------------------------------------------------------------
declare -gA _KNIT_METADATA_CACHE
_KNIT_METADATA_CACHE=()

# ------------------------------------------------------------------------------
# Registration of the metadata command. Its subcommands (store / load / show)
# are registered lazily by _knit_metadata_discover the first time any of them is
# reached, so sourcing knit.sh does not build the subtree up front.
# ------------------------------------------------------------------------------
knit_register metadata knit_empty "Access metadata about the experiment."
_knit_is_builtin
knit_without_provenance
knit_without_history
knit_with_subcommand_discovery _knit_metadata_discover
knit_done

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
    local status=0
    _knit_sqlite3_write "${verb} INTO metadata (key, value) VALUES ('${esc_key}', '${esc_value}');" || status=$?
    # Drop any cached read of this key: a plain INSERT may have been rejected by
    # the uniqueness constraint, so the next read must consult the table again.
    unset '_KNIT_METADATA_CACHE[${key}]'
    return "${status}"
}

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
    # A key already read (or explicitly recorded absent) in this process is
    # served from memory, so repeated reads of the same key (e.g. the profile
    # JSON across many fields) do not re-open the database.
    if [[ -v '_KNIT_METADATA_CACHE[${key}]' ]]; then
        __knit_ret="${_KNIT_METADATA_CACHE[${key}]}"
        return 0
    fi
    local esc_key
    _knit_sql_escape esc_key "${key}"
    __knit_ret=$(_knit_sqlite3 "SELECT value FROM metadata WHERE key = '${esc_key}';")
    _KNIT_METADATA_CACHE[${key}]="${__knit_ret}"
}

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

# ------------------------------------------------------------------------------
# @fn _knit_metadata_is_json()
#
# Return success when the given text is valid JSON, using Knit's jq.
#
# @param[in] value Text to test.
# ------------------------------------------------------------------------------
_knit_metadata_is_json() {
    printf '%s' "$1" | knit_jq -e . >/dev/null 2>&1
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
    # Terminal width, falling back to 80 columns when there is no usable width
    # (_knit_terminal_width returns "0" when stdout is not a terminal).
    local cols
    _knit_terminal_width cols
    (( cols > 0 )) || cols=80
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

# ------------------------------------------------------------------------------
# @fn _knit_metadata_discover()
#
# Register the metadata subcommands (store / load / show). Called lazily by the
# framework the first time a metadata subcommand is resolved, listed in
# "--help", or walked by "describe".
#
# @param[in] parent The parent command's display name (unused).
# ------------------------------------------------------------------------------
_knit_metadata_discover() {
    knit_register "metadata:store" _knit_metadata_store "Store a key/value pair of metadata."
    _knit_is_builtin
    # Storing metadata shapes experiment state, so a replay re-stores it: keep it
    # history-eligible even though its "metadata" parent opts the subtree out.
    knit_with_history
    knit_with_required "key:string" "Key."
    knit_with_required "value:string" "Value."
    knit_with_flag "force" "Overwrite the value if the key already exists."
    knit_done

    knit_register "metadata:load" _knit_metadata_load "Load the value associated with a key in the metadata."
    _knit_is_builtin
    knit_with_required "key:string" "Key."
    knit_done

    knit_register "metadata:show" _knit_metadata_show "Show all the stored metadata."
    _knit_is_builtin
    knit_done
}
