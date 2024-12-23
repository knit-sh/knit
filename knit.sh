#!/bin/bash

################################################################################
# MIT License
#
# Copyright (c) [year] [fullname]
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
################################################################################

KNIT_VERSION=0.0.1

# ------------------------------------------------------------------------------
# This function acts like printf but adds ==> in front and \n after the text.
#
# @param fmt Format string.
# @param ... Arguments for printf.
# ------------------------------------------------------------------------------
knit_log() {
    local fmt=$1
    shift
    printf "==> $fmt\n" $@
}

# ------------------------------------------------------------------------------
# This function takes a comma-separated list of options and searches the list of
# additional arguments to find one of the options. If it finds one, it echos the
# next element in the list, and returns 0. Otherwise, it returns 1.
#
# Example:
# ```
# _knit_find_option "-s,--size" aaa bbb --size ccc
# ```
# will print "ccc" and return 0.
#
# @param options Comma-separated list of options.
# @param ... List of arguments to search from.
# ------------------------------------------------------------------------------
_knit_find_option() {
    local options="$1"   # Comma-separated list of options
    shift                # Remove the first argument (options)
    local list=("$@")    # The rest are the list to search

    # Convert the comma-separated options into an array
    IFS=',' read -r -a option_array <<< "$options"

    # Iterate through the list
    for ((i = 0; i < ${#list[@]}; i++)); do
        # Check if the current element matches any option
        for option in "${option_array[@]}"; do
            if [[ "${list[i]}" == "$option" ]]; then
                # Ensure there's a next element
                if ((i + 1 < ${#list[@]})); then
                    echo "${list[i + 1]}"  # Print the next element
                    return 0  # Return success
                else
                    return 1  # No next element
                fi
            fi
        done
    done

    return 1  # Option not found
}

# ------------------------------------------------------------------------------
# This function takes a comma-separated list of flags and searches the list of
# additional arguments to find one of the flags. If it finds one, it returns 0.
# Otherwise, it returns 1.
#
# Example:
# ```
# _knit_find_option "-h,--help" aaa bbb ccc --help ddd
# ```
# will return 0 because "--help" was found.
#
# @param options Comma-separated list of flagss.
# @param ... List of arguments to search from.
# ------------------------------------------------------------------------------
_knit_find_flag() {
    local flags="$1"  # Comma-separated flags
    shift             # Remove the first argument (flags) to access the list
    local list=("$@") # Store the remaining arguments as the list

    # Convert the comma-separated flags into an array
    IFS=',' read -r -a flag_array <<< "$flags"

    # Check each name against the list
    for flag in "${flag_array[@]}"; do
        for item in "${list[@]}"; do
            if [[ "$item" == "$flag" ]]; then
                return 0 # Found at least one flag
            fi
        done
    done

    return 1 # No flags found
}

# ------------------------------------------------------------------------------
# Print the usage of the script.
# ------------------------------------------------------------------------------
_knit_print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

This script performs the following tasks:
  - Option 1: Does something useful.
  - Option 2: Does something else.
  - Option 3: Yet another useful task.

Options:
  -h, --help    Show this help message and exit.
  -v, --version Show the version of the script.

Example:
  $0 --help
EOF
}

# ------------------------------------------------------------------------------
# This is the main function that invokes the Knit framework. Users should call
# it as follows at the end of their bash script to forward all arguments to it.
#
# ```
# knit $@
# ```
# ------------------------------------------------------------------------------
knit() {
    if [ "$#" -eq 0 ]; then
        _knit_print_usage
    else
        if _knit_find_flag "-h,--help" $@; then
            _knit_print_usage
            exit 0
        fi
        if _knit_find_flag "-v,--version" $@; then
            echo $KNIT_VERSION
            exit 0
        fi
    fi
}
