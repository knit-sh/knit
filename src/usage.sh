#!/bin/bash

# ------------------------------------------------------------------------------
# Print the usage of the script.
# ------------------------------------------------------------------------------
_knit_print_usage() {

    cat << EOF
Usage: $0 [OPTIONS]

Options:
  -h, --help    Show this help message and exit.
  -v, --version Show the version of the script.

Commands:
EOF
    local max_cmd_length=0
    local cmd
    for cmd in "${_KNIT_COMMANDS[@]}"; do
        local str_length=${#cmd}
        if (( str_length > max_cmd_length )); then
            max_cmd_length=$str_length
        fi
    done
    for cmd in "${_KNIT_COMMANDS[@]}"; do
        local description_var="_KNIT_${cmd}_description"
        local description="${!description_var}"
        printf "  %${max_cmd_length}s %s\n" "$cmd" "$description"
    done
}

# ------------------------------------------------------------------------------
# Print a command usage.
#
# @param name Name of the command.
# ------------------------------------------------------------------------------
_knit_print_command_usage() {
    local name=${1}
    local description_var="_KNIT_${name}_description"
    local description="${!description_var}"
    local required_args_varname="_KNIT_${name}_required"
    local -n required_args_ref="${required_args_varname}"
    local optional_args_varname="_KNIT_${name}_optional"
    local -n optional_args_ref="${optional_args_varname}"
    local flags_args_varname="_KNIT_${name}_flags"
    local -n flags_args_ref="${flags_args_varname}"

    cat << EOF
Usage: ${0} ${name} [OPTIONS]

    ${description}

Options:
EOF

    local max_opt_length=0
    local opt
    for opt in "${required_args_ref[@]}"; do
        local opt2="--${opt} <value>"
        local opt_length=${#opt2}
        if (( opt_length > max_opt_length )); then
            max_opt_length=$opt_length
        fi
    done
    for opt in "${optional_args_ref[@]}"; do
        local opt2="--${opt} <value>"
        local opt_length=${#opt2}
        if (( opt_length > max_opt_length )); then
            max_opt_length=$opt_length
        fi
    done
    for opt in "${flags_args_ref[@]}"; do
        local opt2="--${opt}"
        local opt_length=${#opt2}
        #opt_length=$((opt_length + 8))
        if (( opt_length > max_opt_length )); then
            max_opt_length=$opt_length
        fi
    done

    for opt in "${required_args_ref[@]}"; do
        local description_var="_KNIT_${name}_${opt}_description"
        local description="${!description_var}"
        printf "  %${max_opt_length}s %s\n" "--$opt <value>" " [required] $description"
    done
    for opt in "${optional_args_ref[@]}"; do
        local description_var="_KNIT_${name}_${opt}_description"
        local description="${!description_var}"
        local default_var="_KNIT_${name}_${opt}_default"
        local default="${!default_var}"
        printf "  %${max_opt_length}s %s\n" "--$opt <value>" " [default: '$default'] $description"
    done
    max_opt_length=$((max_opt_length - 8))
    for opt in "${flags_args_ref[@]}"; do
        local description_var="_KNIT_${name}_${opt}_description"
        local description="${!description_var}"
        printf "  %${max_opt_length}s %s\n" "--$opt" "         [flag] $description"
    done
}
