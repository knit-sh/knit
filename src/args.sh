#!/bin/bash

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
# @return 0 if the option was found, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_find_option() {
    local options="$1"   # Comma-separated list of options
    shift                # Remove the first argument (options)
    local list=("$@")    # The rest are the list to search

    # Convert the comma-separated options into an array
    IFS=',' read -r -a option_array <<< "$options"

    # Iterate through the list
    local i
    for ((i = 0; i < ${#list[@]}; i++)); do
        # Check if the current element matches any option
        local option
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
# @return 0 if the flag was found, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_find_flag() {
    local flags="$1"  # Comma-separated flags
    shift             # Remove the first argument (flags) to access the list
    local list=("$@") # Store the remaining arguments as the list

    # Convert the comma-separated flags into an array
    IFS=',' read -r -a flag_array <<< "$flags"

    # Check each name against the list
    local flag
    for flag in "${flag_array[@]}"; do
        local item
        for item in "${list[@]}"; do
            if [[ "$item" == "$flag" ]]; then
                return 0 # Found at least one flag
            fi
        done
    done

    return 1 # Flag not found
}

# ------------------------------------------------------------------------------
# This function should be called right after a call to knit_register_command,
# knit_register_job, or knit_register_app, to declare required parameters that
# the command/job/app expects.
#
# Example:
# ```
# knit_register_command "hello"
# knit_with_required "name" "Name of the person to greet"
# ```
# Indicates that the command "hello" requires a parameter --name.
# ------------------------------------------------------------------------------
knit_with_required() {
    if [[ ! -v _KNIT_CURRENT_FUNCTION ]]; then
        knit_fatal "knit_with_required should be called after a knit_register_* function"
    fi
    # TODO description could contain single quotes that should be escaped
    # TODO param could contain "-" characters that should be converted to "_"
    # TODO error if a parameter with the same name is already added (as a required, optional, or flag)
    local fn=$_KNIT_CURRENT_FUNCTION
    local param=$1
    local description="$2"

    local description_var="_KNIT_${fn}_${param}_description"
    eval "$description_var='$description'"
    _knit_set_add "_KNIT_${fn}_required" $param
}

# ------------------------------------------------------------------------------
# This function should be called right after a call to knit_register_command,
# knit_register_job, or knit_register_app, to declare optional parameters that
# the command/job/app may have.
#
# Example:
# ```
# knit_register_command "hello"
# knit_with_optional "name" "Matthieu Dorier" "Name of the person to greet"
# ```
# Indicates that the command "hello" could be provided a parameter --name,
# but this parameter will be set to "Matthieu Dorier" if not provided.
# ------------------------------------------------------------------------------
knit_with_optional() {
    if [[ ! -v _KNIT_CURRENT_FUNCTION ]]; then
        knit_fatal "knit_with_optional should be called after a knit_register_* function"
    fi
    # TODO description could contain single quotes that should be escaped
    # TODO param could contain "-" characters that should be converted to "_"
    # TODO error if a parameter with the same name is already added (as a required, optional, or flag)
    local fn=$_KNIT_CURRENT_FUNCTION
    local param=$1
    local default="$2"
    local description="$3"

    local description_var="_KNIT_${fn}_${param}_description"
    eval "$description_var='$description'"
    local default_var="_KNIT_${fn}_${param}_default"
    eval "$default_var='$default'"
    _knit_set_add "_KNIT_${fn}_optional" $param
}

# ------------------------------------------------------------------------------
# This function should be called right after a call to knit_register_command,
# knit_register_job, or knit_register_app, to declare flags that
# the command/job/app may have. Flags are options without a value. The presence
# of the flag sets it to "true", its absense sets it to false.
#
# Example:
# ```
# knit_register_command "hello"
# knit_with_flag "capitalize" "Whether to capitalize the output"
# ```
# Indicates that the command "hello" could be provided a flag --capitalize.
# ------------------------------------------------------------------------------
knit_with_flag() {
    if [[ ! -v _KNIT_CURRENT_FUNCTION ]]; then
        knit_fatal "knit_with_flag should be called after a knit_register_* function"
    fi
    # TODO description could contain single quotes that should be escaped
    # TODO flag could contain "-" characters that should be converted to "_"
    # TODO error if a parameter with the same name is already added (as a required, optional, or flag)
    local fn=$_KNIT_CURRENT_FUNCTION
    local flag=$1
    local description="$3"

    local description_var="_KNIT_${fn}_${param}_description"
    eval "$description_var='$description'"
    _knit_set_add "_KNIT_${fn}_flags" $flag
}

# ------------------------------------------------------------------------------
# This function retrieves a parameter (optional, required, or flag) from its
# list of arguments. For flags will, it will print "true" or "false".
#
# @param name Name of the option or flag.
# @param ... List of arguments in which to search.
# ------------------------------------------------------------------------------
knit_get_parameter() {
    local option=$1; shift
    _knit_find_option "--$option" $@
}

