#!/usr/bin/env bash
# Driver for profiles.sh (not shown in the documentation). Bootstraps locally,
# then seeds a machine profile into the frozen __profile_json__ metadata the way
# `bootstrap --profile` would, and confirms knit_get_profile_field reads fields
# out of it (and yields empty when the profile or a field is absent).
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project profiles >/dev/null

# No profile was selected at bootstrap, so every field is empty.
check_eq "$(exp sizing)" "scheduler=unknown cores_per_node=unknown" \
    "profile fields are empty without a profile"

# Freeze a profile, then read two fields back out with jq path expressions.
exp metadata store --force --key __profile_json__ \
    --value '{"scheduler":{"type":"slurm"},"hardware":{"cores_per_node":128}}' \
    >/dev/null
check_eq "$(exp sizing)" "scheduler=slurm cores_per_node=128" \
    "knit_get_profile_field reads scheduler.type and hardware.cores_per_node"

dc_summary
