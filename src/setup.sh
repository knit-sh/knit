#!/bin/bash

_KNIT_BUILDS=()

# ------------------------------------------------------------------------------
# Register a build i.e. an operation that aims to build some software and create
#
# @param name Name of the build.
# @param description Description of the build.
#
# Example:
# ```
# knit_register_build "hello" "Builds software that says hello"
# function hello {
#   ...
# }
# ```
# ------------------------------------------------------------------------------
knit_register_build() {
    _knit_register "build" "$@"
}

# ------------------------------------------------------------------------------
# Setup a specified build.
# ------------------------------------------------------------------------------
_knit_invoke_setup() {
    # Check if the first argument is -h or --help
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        _knit_print_setup_usage
        exit 0
    fi
    # Check that the first positional argument (build) is valid
    local build=$1; shift
    if [[ ${build} == --* ]]; then
        _knit_fatal "Invalid build name '${build}'"
    fi
    if [ -z "${build}" ]; then
        _knit_print_setup_usage
        exit 1
    fi
    # Check that the second positional argument (path) is valid
    local path=$1; shift
    if [[ ${path} == --* ]]; then
        _knit_fatal "Invalid build path '${path}'"
    fi
    if [ -z "${path}" ]; then
        _knit_print_setup_usage
        exit 1
    fi
    # Check that the build is registered
    if ! _knit_set_find "_KNIT_BUILDS" "${build}"; then
        knit_fatal "No build with name '${build}' found in this script"
    fi
    # Check the arguments of the build
    local args=("$@")
    # Check if the first argument is -h or --help
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        _knit_print_command_usage "${build}" "$0 setup ${build} <path>"
        exit 0
    fi
    # Check that all the required arguments have been provided
    _knit_check_command_arguments "${build}" "${args[@]}"
    # Add optional arguments and flags
    read -r -a args <<< "$(_knit_expand_command_arguments "${build}" "${args[@]}")"
    # Check if the directory where the environment will be built exists
    if [ -d "${path}" ]; then
        echo "Directory '${path}' already exists."
        read -r -p "Do you want to overwrite this build? [y/N]: " response
        # Default to "no" if the response is empty or not "y/Y"
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "Keeping build at ${path}, exiting."
            exit 0
        fi
        rm -rf "${path}"
    fi
    # Create the directory
    mkdir -p "${path}"
    knit_pushd "${path}" || knit_fatal "Could not pushd into ${path}"
    # Invoke the build function
    "${build}" "${args[@]}"
    knit_popd || knit_fatal "Could not popd from ${path}"
    # Write exported environment
    knit_pushd "${path}" || knit_fatal "Could not pushd into ${path}"
    export -p > .knitenv
    knit_popd || knit_fatal "Could not popd from ${path}"
}
