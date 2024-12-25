#!/bin/bash

_knit_register() {
    local type=$1; shift
    local name=$1; shift
    local description="$@"
    local type_capitalized=${type^^}
    if ! _knit_set_exists "_KNIT_${type_capitalized}S"; then
        _knit_set_new "_KNIT_${type_capitalized}S"
    fi
    if _knit_set_find "_KNIT_${type_capitalized}S" "$name"; then
        knit_fatal "${type^} \"$name\" is already registered"
    fi
    _knit_set_add "_KNIT_${type_capitalized}S" "$name"
    _knit_set_new "_KNIT_${name}_required"
    _knit_set_new "_KNIT_${name}_optional"
    _knit_set_new "_KNIT_${name}_flags"
    eval "_KNIT_${name}_description='$description'"
    _KNIT_CURRENT_FUNCTION=$name
}

# ------------------------------------------------------------------------------
# Register a command, i.e. an operation that should run on the login.
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
    _knit_register "command" $@
}

_knit_invoke_command() {
    local name=$1
    shift
    local args=("$@")
    # Check that all the required arguments have been provided
    local required_args_varname="_KNIT_${name}_required"
    local -n required_args_ref="$required_args_varname"
    local option
    for option in "${required_args_ref[@]}"; do
        local description_var="_KNIT_${name}_${option}_description"
        local description="${!description_var}"
        local value status
        value=$(_knit_find_option "--${option}" ${args[@]})
        status=$?
        if [ $status -ne 0 ]; then
            knit_fatal "Command '$name' requires an option --${option} (${description})"
        fi
    done
    # Add optional arguments that have not been provided
    local optional_args_varname="_KNIT_${name}_optional"
    local -n optional_args_ref="$optional_args_varname"
    for option in "${optional_args_ref[@]}"; do
        local value status
        value=$(_knit_find_option "--${option}" ${args[@]})
        status=$?
        if [ $status -eq 0 ]; then
            continue
        fi
        local default_value_varname="_KNIT_${name}_${option}_default"
        local -n default_value="$default_value_varname"
        args+=("--${option}" $default_value)
    done
    #  Handle flags (add them as option with value "true" or "false")
    local flags_args_varname="_KNIT_${name}_flags"
    local -n flags_args_ref="$flags_args_varname"
    local flag
    for flag in "${flags_args_ref[@]}"; do
        if _knit_find_flag "--${flag}" ${args[@]}; then
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
    # Invoke the actual command
    eval "$name ${args[@]}"
}

