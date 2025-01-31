#!/bin/bash

declare -xr KNIT_VERSION=0.1.0

knit_register knit_empty "__main__" \
    "/!\\ Please use knit_set_program_description to provide a description here /!\\"
knit_hidden
knit_done

# ------------------------------------------------------------------------------
# This is the main function that invokes the Knit framework. Users should call
# it as follows at the end of their bash script to forward all arguments to it.
#
# ```
# knit $@
# ```
# ------------------------------------------------------------------------------
knit() {
    if [[ "$1" == "--help" ]]; then
        (
            _knit_invoke_command "__main__" "--help"
        )
    else
        (
            _knit_invoke_command "$@"
        )
    fi
}
