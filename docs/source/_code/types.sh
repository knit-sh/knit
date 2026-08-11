#!/bin/bash

# Showcase for the Types stitch category: type-annotated parameters (validated
# automatically at invocation), a manual knit_type_check for values that are not
# declared parameters, and a user-defined enum used as a parameter type. Kept to
# the local backend so it runs anywhere with just bash and sqlite3.

source knit.sh

# START annotate
# The ":type" on a parameter is enforced: knit rejects a value that does not match
# the type before the body runs (and the type also picks the database column type).
knit_register "resize" resize "Resize an image to a width and scale factor."
knit_with_required "width:integer" "Target width in pixels."
knit_with_optional "factor:real" "1.0" "Scale factor applied to the width."
resize() {
    echo "width=$(knit_get_parameter "width" "$@") factor=$(knit_get_parameter "factor" "$@")"
}
knit_done
# END annotate

# START type-check
# knit_type_check <type> <value> validates a value by hand (returns 0/1). Use it
# for values that are not declared parameters -- a computed value, an environment
# variable, or a trailing argument.
knit_register "budget" budget "Report whether a budget looks like a number."
knit_with_required "amount:string" "The amount to inspect."
budget() {
    local amount
    amount=$(knit_get_parameter "amount" "$@")
    if knit_type_check "real" "${amount}"; then
        echo "${amount} is a number"
    else
        echo "${amount} is not a number"
    fi
}
knit_done
# END type-check

# START enum
# Define an enum once, then use its name as a parameter type. Knit validates the
# value against the allowed set and lists the accepted values on error.
knit_define_enum "format" "png" "jpeg" "webp"
knit_register "convert" convert "Convert an image to another format."
knit_with_required "to:format" "Target format (one of: $(knit_enum_values "format" ", "))."
convert() {
    echo "converting to $(knit_get_parameter "to" "$@")"
}
knit_done
# END enum

knit "$@"
