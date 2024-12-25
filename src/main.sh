#!/bin/bash

KNIT_VERSION=0.1.0

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
        if _knit_set_find _KNIT_COMMANDS "$1"; then
            _knit_invoke_command $@
        fi
    fi
}
