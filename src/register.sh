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
    local name=$1
    local description=$2
    if ! _knit_set_exists "_KNIT_COMMANDS"; then
        _knit_set_new "_KNIT_COMMANDS"
    fi
    if _knit_set_find "_KNIT_COMMANDS" "$name"; then
        knit_fatal "Command \"$name\" is already registered"
    fi
    _knit_set_add "_KNIT_COMMANDS" "$name"
    _knit_set_new "_KNIT_${name}_required"
    _knit_set_new "_KNIT_${name}_optional"
    _knit_set_new "_KNIT_${name}_flags"
    eval "_KNIT_${name}_description='$description'"
    _KNIT_CURRENT_FUNCTION=$name
}
