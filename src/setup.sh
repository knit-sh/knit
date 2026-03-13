#!/bin/bash

## @file setup.sh

# ------------------------------------------------------------------------------
# Array of registered setup names.
# ------------------------------------------------------------------------------
_KNIT_SETUPS=()

# ------------------------------------------------------------------------------
# @fn knit_register_setup()
#
# Register a setup i.e. an operation that aims to build some software and create
# and environment.
#
# @param name Name of the setup.
# @param description Description of the setup.
#
# Example:
# ```
# knit_register_setup "hello" "Builds software that says hello"
# function hello {
#   ...
# }
# ```
# ------------------------------------------------------------------------------
knit_register_setup() {
    _knit_register "setup" "$@"
}

# ------------------------------------------------------------------------------
# @fn _knit_invoke_setup()
#
# Invoke a specific setup.
#
# @param name Name of the setup to invoke.
# @param path Path in which to setup.
# @param ... Arguments for the setup.
# ------------------------------------------------------------------------------
_knit_invoke_setup() {
    # Check if the first argument is -h or --help
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        _knit_print_setup_usage
        exit 0
    fi
    # Check that the first positional argument (name) is valid
    local name=$1; shift
    if [[ ${name} == --* ]]; then
        _knit_fatal "Invalid setup name '${name}'"
    fi
    if [ -z "${name}" ]; then
        _knit_print_setup_usage
        exit 1
    fi
    # Check that the second positional argument (path) is valid
    local path=$1; shift
    if [[ ${path} == --* ]]; then
        _knit_fatal "Invalid setup path '${path}'"
    fi
    if [ -z "${path}" ]; then
        _knit_print_setup_usage
        exit 1
    fi
    # Check that the setup is registered
    if ! _knit_set_find "_KNIT_SETUPS" "${name}"; then
        knit_fatal "No setup with name '${name}' found in this script"
    fi
    # Check the arguments of the setup
    local args=("$@")
    # Check if the first argument is -h or --help
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        _knit_print_command_usage "${name}" "$0 setup ${name} <path>"
        exit 0
    fi
    # Check that all the required arguments have been provided
    _knit_check_command_arguments "${name}" "${args[@]}"
    # Add optional arguments and flags
    read -r -a args <<< "$(_knit_expand_command_arguments "${name}" "${args[@]}")"
    # Check if the directory where the environment will be built exists
    if [ -d "${path}" ]; then
        echo "Directory '${path}' already exists."
        local response
        read -r -p "Do you want to overwrite this setup? [y/N]: " response
        # Default to "no" if the response is empty or not "y/Y"
        if [[ ! "${response}" =~ ^[Yy]$ ]]; then
            echo "Keeping setup at ${path}, exiting."
            exit 0
        fi
        rm -rf "${path}"
    fi
    # Create the directory
    mkdir -p "${path}"
    knit_pushd "${path}" || knit_fatal "Could not pushd into ${path}"
    # Invoke the build function
    "${name}" "${args[@]}"
    knit_popd || knit_fatal "Could not popd from ${path}"
    # Write exported environment
    knit_pushd "${path}" || knit_fatal "Could not pushd into ${path}"
    export -p > .knitenv
    knit_popd || knit_fatal "Could not popd from ${path}"
}
