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
# @param __knit_ret Name of the variable to hold the value.
# @param key Metadata key to look up.
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
# Show the content of the metadata table of the experiment.
# ------------------------------------------------------------------------------
knit_register "metadata:show" _knit_metadata_show "Show all the stored metadata."
_knit_is_builtin
# ------------------------------------------------------------------------------
# @fn _knit_metadata_show()
#
# Show the content of the metadata table.
# ------------------------------------------------------------------------------
_knit_metadata_show() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    _knit_sqlite3 -header -column "$(printf "SELECT * FROM metadata;")"
}
knit_done
