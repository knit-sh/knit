#!/bin/bash

## @file metadata.sh

# ------------------------------------------------------------------------------
# Registration of the metadata command.
# ------------------------------------------------------------------------------
knit_register knit_empty metadata "Access metadata about the experiment."
_knit_is_builtin
knit_done

# ------------------------------------------------------------------------------
# Store a key/value pair in the metadata table of the experiment.
# ------------------------------------------------------------------------------
knit_register _knit_metadata_store "metadata:store" "Store a key/value pair of metadata."
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
    _knit_sqlite3_write "${verb} INTO metadata (key, value) VALUES ('$(_knit_sql_escape "${key}")', '$(_knit_sql_escape "${value}")');"
}
knit_done

# ------------------------------------------------------------------------------
# Load the value associated with a key from the metadata table.
# ------------------------------------------------------------------------------
knit_register _knit_metadata_load "metadata:load" "Load the value associated with a key in the metadata."
_knit_is_builtin
knit_with_required "key:string" "Key."
# ------------------------------------------------------------------------------
# @fn _knit_metadata_load()
#
# Load the value associated with a key from the metadata table.
# ------------------------------------------------------------------------------
_knit_metadata_load() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    local key
    key=$(knit_get_parameter "key" "$@")
    _knit_sqlite3 "SELECT value FROM metadata WHERE key = '$(_knit_sql_escape "${key}")';"
}
knit_done

# ------------------------------------------------------------------------------
# Show the content of the metadata table of the experiment.
# ------------------------------------------------------------------------------
knit_register _knit_metadata_show "metadata:show" "Show all the stored metadata."
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
