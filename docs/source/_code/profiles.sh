#!/bin/bash

# Showcase for the Profiles stitch recipes: a command that reads fields out of
# the machine profile frozen at bootstrap. Kept to the local backend so the
# driver can seed a profile via metadata and run it on any CI runner.

# START run
source knit.sh
# END run

# START field
knit_register "sizing" sizing "Report placement derived from the machine profile."
sizing() {
    local scheduler cores
    scheduler="$(knit_get_profile_field '.scheduler.type')"
    cores="$(knit_get_profile_field '.hardware.cores_per_node')"
    printf 'scheduler=%s cores_per_node=%s\n' \
        "${scheduler:-unknown}" "${cores:-unknown}"
}
knit_done
# END field

knit "$@"
