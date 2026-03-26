#!/bin/bash

## @file metadata.sh

# ------------------------------------------------------------------------------
# Registration of the metadata command.
# ------------------------------------------------------------------------------
knit_register knit_empty metadata "Access metadata about the experiment."
knit_done

# ------------------------------------------------------------------------------
# Store a key/value pair in the metadata table of the experiment.
# ------------------------------------------------------------------------------
knit_register _knit_metadata_store "metadata:store" "Store a key/value pair of metadata."
knit_with_required "key:string" "Key."
knit_with_required "value:string" "Value."
# ------------------------------------------------------------------------------
# @fn _knit_metadata_store()
#
# Store a key/value pair in the metadata table.
# ------------------------------------------------------------------------------
_knit_metadata_store() {
    local key
    local value
    key=$(knit_get_parameter "key" "$@")
    value=$(knit_get_parameter "value" "$@")
    _knit_sqlite3 "INSERT INTO metadata (key, value) VALUES ('$(__knit_sql_escape "${key}")', '$(__knit_sql_escape "${value}")');"
}
knit_done

# ------------------------------------------------------------------------------
# Load the value associated with a key from the metadata table.
# ------------------------------------------------------------------------------
knit_register _knit_metadata_load "metadata:load" "Load the value associated with a key in the metadata."
knit_with_required "key:string" "Key."
# ------------------------------------------------------------------------------
# @fn _knit_metadata_load()
#
# Load the value associated with a key from the metadata table.
# ------------------------------------------------------------------------------
_knit_metadata_load() {
    local key
    key=$(knit_get_parameter "key" "$@")
    _knit_sqlite3 "SELECT value FROM metadata WHERE key = '$(__knit_sql_escape "${key}")';"
}
knit_done

# ------------------------------------------------------------------------------
# Show the content of the metadata table of the experiment.
# ------------------------------------------------------------------------------
knit_register _knit_metadata_show "metadata:show" "Show all the stored metadata."
# ------------------------------------------------------------------------------
# @fn _knit_metadata_show()
#
# Show the content of the metadata table.
# ------------------------------------------------------------------------------
_knit_metadata_show() {
    _knit_sqlite3 -header -column "$(printf "SELECT * FROM metadata;")"
}
knit_done
