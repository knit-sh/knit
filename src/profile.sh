#!/bin/bash

## @file profile.sh

# ------------------------------------------------------------------------------
# Associative array mapping profile names to their minified JSON content.
# Populated at build time by the Makefile from the JSON files under src/profiles.
# The declaration here is a no-op when knit.sh is built (the Makefile prepends
# the populated array before this file), but allows shellcheck to resolve the
# variable.
# ------------------------------------------------------------------------------
declare -gA _KNIT_PROFILE_JSON

# ------------------------------------------------------------------------------
# @fn knit_list_profiles()
#
# Print the name of each known machine profile, one per line, in sorted order.
# ------------------------------------------------------------------------------
knit_list_profiles() {
    local name
    for name in "${!_KNIT_PROFILE_JSON[@]}"; do
        printf '%s\n' "${name}"
    done | sort
}

# ------------------------------------------------------------------------------
# @fn knit_profile_exists()
#
# Return 0 if the named profile is known, 1 otherwise.
#
# @param profile Name of the profile to look up.
# ------------------------------------------------------------------------------
knit_profile_exists() {
    local profile="$1"
    [[ -v _KNIT_PROFILE_JSON["${profile}"] ]]
}

# ------------------------------------------------------------------------------
# @fn knit_get_profile_field()
#
# Extract one field from a profile's JSON using a jq path expression.
# Prints the field value (without enclosing quotes for strings) or an empty
# string if the field is absent or null.  Returns 1 if the profile is unknown.
#
# @param profile Name of the profile.
# @param jq_path jq path expression, e.g. '.scheduler.type'.
# ------------------------------------------------------------------------------
knit_get_profile_field() {
    local profile="$1"
    local jq_path="$2"
    if ! knit_profile_exists "${profile}"; then
        knit_error "Unknown profile: ${profile}"
        return 1
    fi
    printf '%s' "${_KNIT_PROFILE_JSON[${profile}]}" \
        | _knit_jq -r "${jq_path} // empty"
}

# ------------------------------------------------------------------------------
# @fn _knit_load_profile()
#
# Extract all portable fields from a profile and store them in global variables.
# Called by bootstrap after jq is available.  Returns 1 if the profile is
# unknown.
#
# Sets (empty string when a field is absent):
#   _KNIT_PROFILE_SCHEDULER_TYPE
#   _KNIT_PROFILE_SCHEDULER_COMMAND
#   _KNIT_PROFILE_SCHEDULER_DEFAULT_QUEUE
#   _KNIT_PROFILE_SCHEDULER_DEFAULT_ARGS   (space-joined from JSON array)
#   _KNIT_PROFILE_LAUNCHER_TYPE
#   _KNIT_PROFILE_LAUNCHER_COMMAND
#   _KNIT_PROFILE_LAUNCHER_DEFAULT_ARGS    (space-joined from JSON array)
#   _KNIT_PROFILE_CORES_PER_NODE
#   _KNIT_PROFILE_GPUS_PER_NODE
#
# @param profile Name of the profile to load.
# ------------------------------------------------------------------------------
_knit_load_profile() {
    local profile="$1"
    if ! knit_profile_exists "${profile}"; then
        knit_error "Unknown profile: ${profile}"
        return 1
    fi
    local json="${_KNIT_PROFILE_JSON[${profile}]}"

    _KNIT_PROFILE_SCHEDULER_TYPE=$(printf '%s' "${json}" \
        | _knit_jq -r '.scheduler.type // empty')
    _KNIT_PROFILE_SCHEDULER_COMMAND=$(printf '%s' "${json}" \
        | _knit_jq -r '.scheduler.command // empty')
    _KNIT_PROFILE_SCHEDULER_DEFAULT_QUEUE=$(printf '%s' "${json}" \
        | _knit_jq -r '.scheduler.default_queue // empty')
    _KNIT_PROFILE_SCHEDULER_DEFAULT_ARGS=$(printf '%s' "${json}" \
        | _knit_jq -r '(.scheduler.default_args // []) | join(" ")')
    _KNIT_PROFILE_LAUNCHER_TYPE=$(printf '%s' "${json}" \
        | _knit_jq -r '.launcher.type // empty')
    _KNIT_PROFILE_LAUNCHER_COMMAND=$(printf '%s' "${json}" \
        | _knit_jq -r '.launcher.command // empty')
    _KNIT_PROFILE_LAUNCHER_DEFAULT_ARGS=$(printf '%s' "${json}" \
        | _knit_jq -r '(.launcher.default_args // []) | join(" ")')
    _KNIT_PROFILE_CORES_PER_NODE=$(printf '%s' "${json}" \
        | _knit_jq -r '.hardware.cores_per_node // empty')
    _KNIT_PROFILE_GPUS_PER_NODE=$(printf '%s' "${json}" \
        | _knit_jq -r '.hardware.gpus_per_node // empty')

    knit_trace "Loaded profile ${profile}: scheduler=${_KNIT_PROFILE_SCHEDULER_TYPE}" \
        "launcher=${_KNIT_PROFILE_LAUNCHER_TYPE}" \
        "queue=${_KNIT_PROFILE_SCHEDULER_DEFAULT_QUEUE}"
}

# ------------------------------------------------------------------------------
# Registration of the profile command group.
# ------------------------------------------------------------------------------
knit_register knit_empty profile "List and inspect built-in machine profiles."
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_profile_list()
#
# Implementation of 'knit profile list'.
# ------------------------------------------------------------------------------
_knit_profile_list() {
    knit_list_profiles
}

knit_register _knit_profile_list "profile:list" \
    "List all built-in machine profiles."
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_profile_show()
#
# Implementation of 'knit profile show'.
# ------------------------------------------------------------------------------
_knit_profile_show() {
    local profile
    profile="$(knit_get_parameter "profile" "$@")"
    if ! knit_profile_exists "${profile}"; then
        knit_fatal "Unknown profile: ${profile}. Run 'knit profile list' to see available profiles."
    fi
    local json="${_KNIT_PROFILE_JSON[${profile}]}"
    if _knit_is_bootstrapped; then
        printf '%s' "${json}" | _knit_jq .
    else
        # jq not yet available; pretty-print manually
        printf '%s\n' "${json}"
    fi
}

knit_register _knit_profile_show "profile:show" \
    "Show details of a machine profile."
knit_with_required "profile:string" "Name of the profile to display."
knit_done
