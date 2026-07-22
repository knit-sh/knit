#!/bin/bash

## @file set.sh

# ------------------------------------------------------------------------------
# @fn _knit_set_new()
#
# Create a new empty set (associative array).
#
# A set remembers the order in which elements were first added: alongside the
# backing associative array `NAME`, a companion indexed array `NAME__order`
# records insertion order so that _knit_set_iter() and _knit_set_array() yield
# elements in declaration order rather than the arbitrary hash order of the
# associative array's keys.
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
    declare -ga "${1}__order"
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
    local -n _knit_set_ref="$1"
    [[ -v _knit_set_ref["$2"] ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_set_add()
#
# Add one or more elements to a set. Each element that is not already present is
# appended to the set's companion order array, so iteration reflects the order
# in which elements were first added. Duplicates are ignored (neither re-added
# nor re-ordered). The order array is created lazily, so this works on sets
# declared directly with `declare -gA` as well as those created via
# _knit_set_new().
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
    # shellcheck disable=SC2178 # nameref to associative array
    local -n _knit_set_ref="$1"
    declare -ga "${1}__order"
    # shellcheck disable=SC2178 # nameref to indexed array
    local -n _knit_set_order="${1}__order"
    shift
    local item
    for item in "$@"; do
        if [[ ! -v _knit_set_ref["${item}"] ]]; then
            _knit_set_ref["${item}"]=1
            _knit_set_order+=("${item}")
        fi
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_set_iter()
#
# Print each element of a set on its own line, in insertion (declaration) order.
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
    # shellcheck disable=SC2178 # nameref to indexed array
    local -n _knit_set_order="${1}__order"
    local key
    for key in "${_knit_set_order[@]}"; do
        printf '%s\n' "${key}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_set_array()
#
# Return a set's elements, in insertion (declaration) order, as an indexed array
# written through a nameref output parameter. This is the fork-free alternative
# to `while read … < <(_knit_set_iter …)`.
#
# Example:
# ```
# local -a members
# _knit_set_array members MY_SET
# ```
#
# @param out Name of the array variable to populate (nameref output).
# @param set_name Name of the set to read.
# ------------------------------------------------------------------------------
_knit_set_array() {
    local -n __knit_ret=$1
    # shellcheck disable=SC2178 # nameref to indexed array
    local -n _knit_set_order="${2}__order"
    __knit_ret=("${_knit_set_order[@]}")
}

# ------------------------------------------------------------------------------
# @fn _knit_set_remove()
#
# Remove one or more elements from a set, keeping the companion order array
# consistent.
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
    local -n _knit_set_ref="$1"
    # shellcheck disable=SC2178 # nameref to indexed array
    local -n _knit_set_order="${1}__order"
    shift
    local item
    for item in "$@"; do
        unset '_knit_set_ref[${item}]'
    done
    # Rebuild the order array, dropping any element no longer in the set.
    local -a _knit_kept=()
    local key
    for key in "${_knit_set_order[@]}"; do
        if [[ -v _knit_set_ref["${key}"] ]]; then
            _knit_kept+=("${key}")
        fi
    done
    _knit_set_order=("${_knit_kept[@]}")
}
