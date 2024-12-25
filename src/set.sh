#!/bin/bash

# ------------------------------------------------------------------------------
# Create a new empty set (sorted array).
#
# Example:
# ```
# _knit_set_new MY_SET
# ```
#
# @param array_name Name of the set to create.
# ------------------------------------------------------------------------------
_knit_set_new() {
    local array_name="$1"
    eval "$array_name=()"
}

# ------------------------------------------------------------------------------
# Find an element in a sorted array using binary search.
#
# Example:
# ```
# MY_SET=("Matthieu" "Phil" "Rob")
# _knit_set_find MY_SET "Phil"
# ```
#
# @param array_name Name of the set in which to search.
# @param item Item to find.
# @return 0 if the element is found, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_set_find() {
    local array_name="$1"
    local item="$2"
    local -n array_ref="$array_name"

    local low=0
    local high=$(( ${#array_ref[@]} - 1 ))

    while (( low <= high )); do
        local mid=$(( (low + high) / 2 ))
        if [[ "${array_ref[mid]}" == "$item" ]]; then
            return 0
        elif [[ "${array_ref[mid]}" < "$item" ]]; then
            low=$(( mid + 1 ))
        else
            high=$(( mid - 1 ))
        fi
    done
    return 1
}

# ------------------------------------------------------------------------------
# Add one or more elements to a set.
#
# Example:
# ```
# _knit_set_add MY_SET "Shane" "Matthieu" "Rob"
# ```
#
# @param array_name Name of the set in which to add the element.
# @param ...items Elements to add to the set.
# ------------------------------------------------------------------------------
_knit_set_add() {

    local array_name="$1"
    local -n array_ref="$array_name"
    shift

    for item in "$@"; do

        local low=0
        local high=${#array_ref[@]}
        local mid=0

        while (( low < high )); do
            mid=$(( (low + high) / 2 ))
            if [[ "${array_ref[mid]}" == "$item" ]]; then
                break
            elif [[ "${array_ref[mid]}" < "$item" ]]; then
                low=$(( mid + 1 ))
            else
                high=$mid
            fi
        done
        array_ref=( "${array_ref[@]:0:low}" "$item" "${array_ref[@]:low}" )

    done
}

# ------------------------------------------------------------------------------
# Remove one or more elements from a set.
#
# Example:
# ```
# _knit_set_remove MY_SET "Shane" "Matthieu"
# ```
#
# @param array_name Name of the set in which to remove the elements.
# @param ...items Elements to remove from the set.
# ------------------------------------------------------------------------------
_knit_set_remove() {
    local array_name="$1"
    local -n array_ref="$array_name"
    shift

    for item in "$@"; do

        local low=0
        local high=$(( ${#array_ref[@]} - 1 ))
        local mid=0

        while (( low <= high )); do
            mid=$(( (low + high) / 2 ))
            if [[ "${array_ref[mid]}" == "$item" ]]; then
                array_ref=( "${array_ref[@]:0:mid}" "${array_ref[@]:mid+1}" )
                break
            elif [[ "${array_ref[mid]}" < "$item" ]]; then
                low=$(( mid + 1 ))
            else
                high=$(( mid - 1 ))
            fi
        done

    done
}
