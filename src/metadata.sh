#!/bin/bash

# ------------------------------------------------------------------------------
# Registration of the metadata command.
# ------------------------------------------------------------------------------
knit_register knit_empty metadata "Access metadata about the experiment."
knit_done

# ------------------------------------------------------------------------------
# Store a key/value pair in the metadata table of the experiment.
# ------------------------------------------------------------------------------
knit_register _knit_metadata_store "metadata:store" "Store a key/value pair of metadata."
knit_with_required "key" "Key."
knit_with_required "value" "Value."
_knit_metadata_store() {
    local key
    local value
    key=$(knit_get_parameter "key" "$@")
    value=$(knit_get_parameter "value" "$@")
    _knit_sqlite3 "$(printf "INSERT INTO metadata (key, value) VALUES ('%q', '%q');" "${key}" "${value}")"
}
knit_done

# ------------------------------------------------------------------------------
# Load the value associated with a key from the metadata table.
# ------------------------------------------------------------------------------
knit_register _knit_metadata_load "metadata:load" "Load the value associated with a key in the metadata."
knit_with_required "key" "Key."
_knit_metadata_load() {
    local key
    key=$(knit_get_parameter "key" "$@")
    _knit_sqlite3 "$(printf "SELECT value FROM metadata WHERE key = '%q';" "${key}")"
}
knit_done

# ------------------------------------------------------------------------------
# Show the content of the metadata table of the experiment.
# ------------------------------------------------------------------------------
knit_register _knit_metadata_show "metadata:show" "Show all the stored metadata."
_knit_metadata_show() {
    _knit_sqlite3 -header -column "$(printf "SELECT * FROM metadata;")"
}
knit_done
