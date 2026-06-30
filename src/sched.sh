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
