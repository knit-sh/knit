#!/bin/bash

_knit_register() {
    local type="$1"; shift
    local name="$1"; shift
    local description="$*"
    local type_capitalized="${type^^}"
    if ! _knit_set_exists "_KNIT_${type_capitalized}S"; then
        _knit_set_new "_KNIT_${type_capitalized}S"
    fi
    if _knit_set_find "_KNIT_${type_capitalized}S" "${name}"; then
        knit_fatal "${type^} \"${name}\" is already registered"
    fi
    _knit_set_add "_KNIT_${type_capitalized}S" "${name}"
    _knit_set_new "_KNIT_${name}_required"
    _knit_set_new "_KNIT_${name}_optional"
    _knit_set_new "_KNIT_${name}_flags"
    eval "_KNIT_${name}_description='${description}'"
    _KNIT_CURRENT_FUNCTION="${name}"
}

# ------------------------------------------------------------------------------
# Register a command, i.e. an operation that should run on the login node.
#
# @param name Name of the command.
# @param description Description of the command.
#
# Example:
# ```
# knit_register_command "hello" "Says hello"
# function hello {
#   ...
# }
# ```
# ------------------------------------------------------------------------------
knit_register_command() {
    _knit_register "command" "$@"
}

# ------------------------------------------------------------------------------
# Check that the arguments expected by the command are provided. This command
# will fail with a fatal error (i.e. the script will stop) if a required
# argument is not provided.
#
# @param name Name of the command.
# @param ... Arguments to pass to the command.
# ------------------------------------------------------------------------------
_knit_check_command_arguments() {
    local name="$1"
    shift
    local args=("$@")
    # Check that all the required arguments have been provided
    local required_args_varname="_KNIT_${name}_required"
    local -n required_args_ref="${required_args_varname}"
    local option
    for option in "${required_args_ref[@]}"; do
        local description_var="_KNIT_${name}_${option}_description"
        local description="${!description_var}"
        local status
        _knit_find_option "--${option}" "${args[@]}" > /dev/null
        status=$?
        if [ ${status} -eq 0 ]; then
            continue
        fi
        local other_format
        other_format=$(_knit_str_underscores_to_hyphens "${option}")
        knit_fatal "Command '${name}' requires an option --${option} or --${other_format} (${description})"
    done
}

# ------------------------------------------------------------------------------
# Adds optional arguments that are not provided in the arguments, and converts
# flags into --flag true or --flag false.
#
# @param name Name of the command.
# @param ... Arguments to pass to the command.
# ------------------------------------------------------------------------------
_knit_expand_command_arguments() {
    local name="$1"
    shift
    local args=("$@")
    # Add optional arguments that have not been provided
    local optional_args_varname="_KNIT_${name}_optional"
    local -n optional_args_ref="${optional_args_varname}"
    for option in "${optional_args_ref[@]}"; do
        local status
        _knit_find_option "--${option}" "${args[@]}" > /dev/null
        status="$?"
        if [ ${status} -eq 0 ]; then
            continue
        fi
        local default_value_varname="_KNIT_${name}_${option}_default"
        local -n default_value="${default_value_varname}"
        args+=("--${option}" "${default_value}")
    done
    # Handle flags (add them as option with value "true" or "false")
    local flags_args_varname="_KNIT_${name}_flags"
    local -n flags_args_ref="${flags_args_varname}"
    local flag
    for flag in "${flags_args_ref[@]}"; do
        if _knit_find_flag "--${flag}" "${args[@]}"; then
            local i
            for i in "${!args[@]}"; do
                if [[ "${args[$i]}" == "--${flag}" ]]; then
                    # Insert "true" after the flag
                    args=("${args[@]:0:i+1}" "true" "${args[@]:i+1}")
                    break
                fi
            done
        else
            args+=("--${flag}" "false")
        fi
    done
    # Print the resulting arguments
    echo "${args[*]}"
}

# ------------------------------------------------------------------------------
# Invoke a command.
#
# @param name Name of the command to invoke.
# @param ... Arguments to pass to the command.
# ------------------------------------------------------------------------------
_knit_invoke_command() {
    local name="$1"
    shift
    local args=("$@")
    # Check if the first argument is -h or --help
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        _knit_print_command_usage "${name}"
        exit 0
    fi
    # Check that all the required arguments have been provided
    _knit_check_command_arguments "${name}" "${args[@]}"
    # Add optional arguments and flags
    read -r -a args <<< "$(_knit_expand_command_arguments "${name}" "${args[@]}")"
    # Invoke the actual command
    "${name}" "${args[@]}"
}
