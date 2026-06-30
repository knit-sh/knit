#!/bin/bash

## @file sched.sh

# ------------------------------------------------------------------------------
# @fn _knit_uuidv7()
#
# Generate a version-7 UUID (RFC 9562) and print it to stdout.
#
# A uuidv7 encodes a 48-bit big-endian Unix millisecond timestamp in its leading
# bits, so lexically sorting uuidv7 strings orders them by creation time. This is
# why job directories are named with one: they sort chronologically.
#
# Layout (hex digits, formatted 8-4-4-4-12):
#   - digits  1-12 : 48-bit millisecond timestamp
#   - digit  13    : version nibble, always "7"
#   - digits 14-16 : random
#   - digit  17    : variant nibble, one of 8, 9, a, b
#   - digits 18-32 : random
#
# Randomness comes from /dev/urandom when available, falling back to the bash
# ${RANDOM} generator; the timestamp prefix guarantees ordering and near
# uniqueness even in the fallback case. The millisecond clock falls back to
# whole-second precision when `date` lacks nanosecond (%N) support.
# ------------------------------------------------------------------------------
_knit_uuidv7() {
    local ms
    ms="$(date +%s%3N 2>/dev/null)"
    if [[ ! "${ms}" =~ ^[0-9]+$ ]]; then
        ms=$(( $(date +%s) * 1000 ))
    fi

    local ts_hex
    ts_hex="$(printf '%012x' "${ms}")"
    # Keep the low 48 bits (12 hex digits) in case of an unexpectedly wide value.
    ts_hex="${ts_hex: -12}"

    local rand
    rand="$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null \
        | tr -d ' \n')"
    while [[ "${#rand}" -lt 32 ]]; do
        rand+="$(printf '%04x' "$(( RANDOM ))")"
    done

    # Variant nibble: top two bits "10" -> one of 8, 9, a, b.
    local variant
    variant=$(( (16#${rand:3:1} & 0x3) | 0x8 ))

    printf '%s-%s-7%s-%x%s-%s\n' \
        "${ts_hex:0:8}" "${ts_hex:8:4}" "${rand:0:3}" \
        "${variant}" "${rand:4:3}" "${rand:7:12}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_profile_field()
#
# Print a field from a machine profile's JSON, or nothing when the profile name
# is empty or unknown. A thin guard around knit_get_profile_field so callers can
# request a field unconditionally without emitting an "unknown profile" error.
#
# @param profile Profile name (may be empty).
# @param jq_path jq path expression, e.g. '.scheduler.default_queue'.
# ------------------------------------------------------------------------------
_knit_sched_profile_field() {
    local profile="$1"
    local jq_path="$2"
    if [[ -n "${profile}" ]] && knit_profile_exists "${profile}"; then
        knit_get_profile_field "${profile}" "${jq_path}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_resolve()
#
# Resolve the submission options for a job into a caller-provided associative
# array. For each option the value is resolved by precedence:
#
#   explicit CLI argument -> bootstrap metadata -> machine profile -> hard-coded
#
# The array is keyed by canonical option name (job-name, account, project,
# queue, nodes, cpus-per-node, walltime, gpus-per-node, wait) plus "extra-args"
# for the site-mandatory scheduler arguments captured at bootstrap. The per-node
# core count (cpus-per-node) is derived rather than requested (knit allocates
# whole nodes). Job stdout/stderr are fixed to <job-dir>/.stdout and
# <job-dir>/.stderr by the backend, so they are not resolved here.
#
# @param out_array Name of an associative array to populate (passed by name).
# @param ...       The submission CLI arguments (everything before "--").
# ------------------------------------------------------------------------------
_knit_sched_resolve() {
    local -n resolved="$1"
    shift
    local -a cli=("$@")

    local profile
    profile="$(_knit_metadata_load --key "__profile__")"

    local v

    # Identity ------------------------------------------------------------------
    v="$(knit_get_parameter "job-name" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="${KNIT_SCRIPT_NAME}"
    resolved["job-name"]="${v}"

    v="$(knit_get_parameter "account" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="$(_knit_metadata_load --key "__account__")"
    resolved["account"]="${v}"

    v="$(knit_get_parameter "project" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="$(_knit_metadata_load --key "__project__")"
    resolved["project"]="${v}"

    v="$(knit_get_parameter "queue" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="$(_knit_metadata_load --key "__default_queue__")"
    [[ -z "${v}" ]] && v="$(_knit_sched_profile_field "${profile}" '.scheduler.default_queue')"
    resolved["queue"]="${v}"

    # Resources -----------------------------------------------------------------
    v="$(knit_get_parameter "nodes" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="1"
    resolved["nodes"]="${v}"

    # Per-node core count is derived, not requested: knit allocates whole nodes,
    # so this comes from the bootstrap-detected/profile value. It drives ncpus and
    # mpiprocs on PBS and --ntasks-per-node on Slurm. Empty when unknown (no
    # profile and no detection); the backend then omits the per-node CPU directive.
    v="$(_knit_metadata_load --key "__node_ncpus__")"
    [[ -z "${v}" ]] && v="$(_knit_sched_profile_field "${profile}" '.hardware.cores_per_node')"
    resolved["cpus-per-node"]="${v}"

    v="$(knit_get_parameter "gpus-per-node" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="0"
    resolved["gpus-per-node"]="${v}"

    # Walltime falls back to the resolved queue's profile cap, then to one hour.
    v="$(knit_get_parameter "walltime" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="$(_knit_metadata_load --key "__default_walltime__")"
    if [[ -z "${v}" && -n "${resolved["queue"]}" ]]; then
        v="$(_knit_sched_profile_field "${profile}" \
            ".scheduler.queues.\"${resolved["queue"]}\".max_walltime")"
    fi
    [[ -z "${v}" ]] && v="01:00:00"
    resolved["walltime"]="${v}"

    # Behaviour -----------------------------------------------------------------
    v="$(knit_get_parameter "wait" "${cli[@]}")" || v="false"
    resolved["wait"]="${v}"

    # Site-mandatory scheduler arguments captured at bootstrap ------------------
    v="$(_knit_metadata_load --key "__default_scheduler_args__")"
    [[ -z "${v}" ]] && v="$(_knit_sched_profile_field "${profile}" \
        '(.scheduler.default_args // []) | join(" ")')"
    resolved["extra-args"]="${v}"
}
