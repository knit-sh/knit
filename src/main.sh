#!/bin/bash

declare -xr KNIT_VERSION=0.1.0

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
        if [[ "$1" == "-h" || "$1" == "--help" ]]; then
            _knit_print_usage
            exit 0
        fi
        if [[ "$1" == "-v" || "$1" == "--version" ]]; then
            echo $KNIT_VERSION
            exit 0
        fi
        local args=($(_knit_expand_keyval_args "$@"))
        if _knit_set_find _KNIT_COMMANDS "${args[0]}"; then
            _knit_invoke_command "${args[@]}"
        elif [[ "${args[0]}" == "bootstrap" ]]; then
            args=("${args[@]:1}")
            _knit_bootstrap "${args[@]}"
        elif [[ "${args[0]}" == "setup" ]]; then
            args=("${args[@]:1}")
            _knit_invoke_setup "${args[@]}"
        elif [[ "${args[0]}" == "submit" ]]; then
            args=("${args[@]:1}")
            # TODO
            knit_fatal "Command 'submit' is not yet implemented"
        elif [[ "${args[0]}" == "run" ]]; then
            args=("${args[@]:1}")
            # TODO
            knit_fatal "Command 'run' is not yet implemented"
        else
            knit_fatal "Unknown command '${args[0]}'"
        fi
    fi
}
