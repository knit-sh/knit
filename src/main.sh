#!/bin/bash

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
        if _knit_find_flag "-h,--help" $@; then
            _knit_print_usage
            exit 0
        fi
        if _knit_find_flag "-v,--version" $@; then
            echo $KNIT_VERSION
            exit 0
        fi
    fi
}
