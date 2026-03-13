#!/bin/bash

## @file set.sh

# ------------------------------------------------------------------------------
# @fn _knit_set_new()
#
# Create a new empty set (associative array).
#
# Example:
# ```
# _knit_set_new MY_SET
# ```
#
# @param set_name Name of the set to create.
# ------------------------------------------------------------------------------
_knit_set_new() {
    declare -gA "$1"
}

# ------------------------------------------------------------------------------
# @fn _knit_set_exists()
#
# Checks if a set with the given name is defined, i.e. the variable is defined
# and it is an associative array.
#
# Example:
# ```
# _knit_set_exists MY_SET
# ```
#
# @param set_name Name of the set.
# ------------------------------------------------------------------------------
_knit_set_exists() {
    local set_name="$1"
    local declare_out
    declare_out=$(declare -p "${set_name}" 2>/dev/null) || return 1
    [[ "${declare_out}" =~ "declare -A" ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_set_find()
#
# Check if an element exists in a set.
#
# Example:
# ```
# _knit_set_find MY_SET "Phil"
# ```
#
# @param set_name Name of the set in which to search.
# @param item Item to find.
# @return 0 if the element is found, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_set_find() {
    local -n __knit_set_ref="$1"
    [[ -v __knit_set_ref["$2"] ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_set_add()
#
# Add one or more elements to a set.
#
# Example:
# ```
# _knit_set_add MY_SET "Shane" "Matthieu" "Rob"
# ```
#
# @param set_name Name of the set in which to add the element.
# @param ...items Elements to add to the set.
# ------------------------------------------------------------------------------
_knit_set_add() {
    local -n __knit_set_ref="$1"
    shift
    local item
    for item in "$@"; do
        __knit_set_ref["${item}"]=1
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_set_iter()
#
# Print each element of a set on its own line.
#
# Example:
# ```
# _knit_set_iter MY_SET | while read -r key; do
#     echo "Key: $key"
# done
# ```
#
# @param set_name Name of the set to iterate over.
# ------------------------------------------------------------------------------
_knit_set_iter() {
    # shellcheck disable=SC2178 # nameref to associative array
    local -n __knit_set_ref="$1"
    local key
    for key in "${!__knit_set_ref[@]}"; do
        printf '%s\n' "${key}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_set_remove()
#
# Remove one or more elements from a set.
#
# Example:
# ```
# _knit_set_remove MY_SET "Shane" "Matthieu"
# ```
#
# @param set_name Name of the set from which to remove the elements.
# @param ...items Elements to remove from the set.
# ------------------------------------------------------------------------------
_knit_set_remove() {
    # shellcheck disable=SC2178 # nameref to associative array
    local -n __knit_set_ref="$1"
    shift
    local item
    for item in "$@"; do
        unset '__knit_set_ref[${item}]'
    done
}
