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
    max_cmd_length=0
    for str in "${_KNIT_COMMANDS[@]}"; do
        str_length=${#str}
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
