#!/bin/bash

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
    # TODO error if another command exists with the same name
    local name=$1
    _knit_set_new "_KNIT_${name}_required"
    _knit_set_new "_KNIT_${name}_optional"
    _knit_set_new "_KNIT_${name}_flags"
    _KNIT_CURRENT_FUNCTION=$name
}
