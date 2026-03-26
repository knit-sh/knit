#!/bin/bash

## @file types.sh

# ------------------------------------------------------------------------------
# @var __KNIT_TYPE_ALIASES
#
# Associative array mapping type alias names to their canonical type names.
# ------------------------------------------------------------------------------
declare -gA __KNIT_TYPE_ALIASES
__KNIT_TYPE_ALIASES=([int]=integer [double]=real [float]=real [bool]=boolean)

# ------------------------------------------------------------------------------
# @var __KNIT_BUILTIN_TYPES
#
# Set of built-in canonical type names.
# ------------------------------------------------------------------------------
declare -gA __KNIT_BUILTIN_TYPES
__KNIT_BUILTIN_TYPES=(
    [integer]=1
    [real]=1
    [boolean]=1
    [string]=1
    [path]=1
    [file]=1
    [filename]=1
    [date]=1
    [time]=1
    [datetime]=1
    [uuid]=1
)

# ------------------------------------------------------------------------------
# @var __KNIT_ENUMS
#
# Set of user-defined enum type names.
# ------------------------------------------------------------------------------
declare -gA __KNIT_ENUMS

# ------------------------------------------------------------------------------
# @fn __knit_type_resolve_alias()
#
# Resolve a type name or alias to its canonical type name. If the name is
# already a canonical built-in type or an enum, it is returned as-is. If it
# is an alias, the corresponding canonical name is printed.
#
# Example:
# ```
# __knit_type_resolve_alias "int"      # prints "integer"
# __knit_type_resolve_alias "integer"  # prints "integer"
# __knit_type_resolve_alias "color"    # prints "color" (if enum defined)
# ```
#
# @param type_name Type name or alias to resolve.
# @return 0 if resolved successfully, 1 if the name is unknown.
# ------------------------------------------------------------------------------
__knit_type_resolve_alias() {
    local name="$1"
    if [[ -v __KNIT_TYPE_ALIASES["${name}"] ]]; then
        printf '%s\n' "${__KNIT_TYPE_ALIASES[${name}]}"
        return 0
    fi
    if [[ -v __KNIT_BUILTIN_TYPES["${name}"] ]]; then
        printf '%s\n' "${name}"
        return 0
    fi
    if [[ -v __KNIT_ENUMS["${name}"] ]]; then
        printf '%s\n' "${name}"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# @fn knit_type_exists()
#
# Check whether a type name is valid. Returns 0 if the name is a built-in
# type, a type alias, or a user-defined enum.
#
# Example:
# ```
# knit_type_exists "integer"    # returns 0
# knit_type_exists "int"        # returns 0 (alias for integer)
# knit_type_exists "unknown"    # returns 1
# ```
#
# @param type_name Type name to check.
# @return 0 if the type exists, 1 otherwise.
# ------------------------------------------------------------------------------
knit_type_exists() {
    __knit_type_resolve_alias "$1" > /dev/null
}

# ------------------------------------------------------------------------------
# @fn knit_define_enum()
#
# Define a new enum type with the given name and possible values.
#
# Example:
# ```
# knit_define_enum "color" "red" "green" "blue"
# ```
#
# @param name Name of the enum type to define.
# @param ...values Possible values for the enum.
# ------------------------------------------------------------------------------
knit_define_enum() {
    local name="$1"
    shift
    __KNIT_ENUMS["${name}"]=1
    _knit_set_new "__KNIT_ENUM_${name}"
    _knit_set_add "__KNIT_ENUM_${name}" "$@"
}

# ------------------------------------------------------------------------------
# @fn knit_enum_values()
#
# Print the possible values of an enum type. By default, values are separated
# by newlines. If a second argument is provided, it is used as the separator
# instead.
#
# Example:
# ```
# knit_enum_values "color"          # prints each value on its own line
# knit_enum_values "color" ", "     # prints "red, green, blue"
# ```
#
# @param name Name of the enum type.
# @param separator Optional separator (default: newline).
# @return 1 if the enum does not exist.
# ------------------------------------------------------------------------------
knit_enum_values() {
    local name="$1"
    local set_name="__KNIT_ENUM_${name}"
    if [[ ! -v __KNIT_ENUMS["${name}"] ]]; then
        return 1
    fi
    if [[ $# -lt 2 ]]; then
        _knit_set_iter "${set_name}"
    else
        local sep="$2"
        local first=1
        local key
        while read -r key; do
            if [[ "${first}" -eq 1 ]]; then
                first=0
            else
                printf '%s' "${sep}"
            fi
            printf '%s' "${key}"
        done < <(_knit_set_iter "${set_name}")
        if [[ "${first}" -eq 0 ]]; then
            printf '\n'
        fi
    fi
}

# ------------------------------------------------------------------------------
# @fn __knit_type_check_date()
#
# Validate that a string is a date in YYYY-MM-DD format with valid ranges.
#
# @param value String to validate.
# @return 0 if valid, 1 otherwise.
# ------------------------------------------------------------------------------
__knit_type_check_date() {
    local value="$1"
    local date_re='^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
    [[ "${value}" =~ ${date_re} ]] || return 1
    local month=$((10#${BASH_REMATCH[2]}))
    local day=$((10#${BASH_REMATCH[3]}))
    (( month >= 1 && month <= 12 && day >= 1 && day <= 31 ))
}

# ------------------------------------------------------------------------------
# @fn __knit_type_check_time()
#
# Validate that a string is a time in hh:mm:ss format with valid ranges.
#
# @param value String to validate.
# @return 0 if valid, 1 otherwise.
# ------------------------------------------------------------------------------
__knit_type_check_time() {
    local value="$1"
    local time_re='^([0-9]{2}):([0-9]{2}):([0-9]{2})$'
    [[ "${value}" =~ ${time_re} ]] || return 1
    local hour=$((10#${BASH_REMATCH[1]}))
    local minute=$((10#${BASH_REMATCH[2]}))
    local second=$((10#${BASH_REMATCH[3]}))
    (( hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59 && second >= 0 && second <= 59 ))
}

# ------------------------------------------------------------------------------
# @fn knit_type_check()
#
# Check whether a value conforms to the specified type. For enum types, checks
# that the value is one of the defined enum values.
#
# Type validation rules:
# - integer: optional sign followed by digits
# - real: decimal number with optional exponent (e.g. 3.14, .5, 1e10)
# - boolean: "true" or "false"
# - string: any value (always passes)
# - path, filename: non-empty string
# - file: path to an existing file
# - date: YYYY-MM-DD with valid month/day ranges
# - time: hh:mm:ss with valid hour/minute/second ranges
# - datetime: "YYYY-MM-DD hh:mm:ss" combining date and time rules
#
# Example:
# ```
# knit_type_check "integer" "42"          # returns 0
# knit_type_check "integer" "hello"       # returns 1
# knit_type_check "date" "2025-03-13"     # returns 0
# knit_type_check "color" "red"           # returns 0 (if color enum defined)
# ```
#
# @param type Type name (or alias) to check against.
# @param value Value to validate.
# @return 0 if the value is valid for the type, 1 otherwise.
# ------------------------------------------------------------------------------
knit_type_check() {
    local type="$1"
    local value="$2"
    local resolved
    resolved=$(__knit_type_resolve_alias "${type}") || return 1

    local integer_re='^-?[0-9]+$'
    local real_re='^-?([0-9]+\.?[0-9]*|[0-9]*\.[0-9]+)([eE][+-]?[0-9]+)?$'
    local datetime_re='^([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]([0-9]{2}:[0-9]{2}:[0-9]{2})$'

    case "${resolved}" in
        integer)
            [[ "${value}" =~ ${integer_re} ]]
            ;;
        real)
            [[ "${value}" =~ ${real_re} ]]
            ;;
        boolean)
            [[ "${value}" = "true" || "${value}" = "false" ]]
            ;;
        string)
            return 0
            ;;
        path|filename)
            [[ -n "${value}" ]]
            ;;
        file)
            [[ -f "${value}" ]]
            ;;
        date)
            __knit_type_check_date "${value}"
            ;;
        time)
            __knit_type_check_time "${value}"
            ;;
        datetime)
            [[ "${value}" =~ ${datetime_re} ]] || return 1
            local __date_part="${BASH_REMATCH[1]}"
            local __time_part="${BASH_REMATCH[2]}"
            __knit_type_check_date "${__date_part}" \
                && __knit_type_check_time "${__time_part}"
            ;;
        uuid)
            local uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            [[ "${value}" =~ ${uuid_re} ]]
            ;;
        *)
            # Enum type
            _knit_set_find "__KNIT_ENUM_${resolved}" "${value}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn __knit_type_to_sqlite()
#
# Map a Knit type name (or alias) to its corresponding SQLite type affinity.
# Returns INTEGER for integer, REAL for real, and TEXT for all other types
# (including boolean, string, path, file, filename, date, time, datetime, uuid,
# and user-defined enums).
#
# Example:
# ```
# __knit_type_to_sqlite "integer"  # prints: INTEGER
# __knit_type_to_sqlite "real"     # prints: REAL
# __knit_type_to_sqlite "uuid"     # prints: TEXT
# __knit_type_to_sqlite "int"      # prints: INTEGER (alias resolved)
# ```
#
# @param type_name Knit type name or alias.
# @return 0 on success, 1 if the type is unknown.
# ------------------------------------------------------------------------------
__knit_type_to_sqlite() {
    local resolved
    resolved=$(__knit_type_resolve_alias "$1") || return 1
    case "${resolved}" in
        integer) printf 'INTEGER' ;;
        real)    printf 'REAL' ;;
        *)       printf 'TEXT' ;;
    esac
}
