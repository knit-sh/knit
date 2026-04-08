#!/usr/bin/env bash
# Integration test experiment 02_setup_basic.
#
# Registers a single setup called "basic" that:
#   1. Writes a greeting file into $KNIT_SETUP_PREFIX
#   2. Exports MY_GREETING so it ends up in .activate.sh

source /shared/knit/knit.sh

knit_set_program_description "Basic setup integration test experiment."

knit_register_setup "basic" __basic_setup_fn "Write a greeting file."
knit_with_required "message:string" "Greeting message to write."
__basic_setup_fn() {
    local message
    message=$(knit_get_parameter "message" "$@")

    # Write the message to a file in the setup directory.
    printf '%s\n' "${message}" > "${KNIT_SETUP_PREFIX}/greeting.txt"

    # Export a variable so it appears in .activate.sh.
    export MY_GREETING="${message}"
}
knit_done

knit "$@"
