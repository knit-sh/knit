#!/bin/bash

## @file types.sh

# ------------------------------------------------------------------------------
# @var _KNIT_TYPE_ALIASES
#
# Associative array mapping type alias names to their canonical type names.
# ------------------------------------------------------------------------------
declare -gA _KNIT_TYPE_ALIASES
_KNIT_TYPE_ALIASES=([int]=integer [double]=real [float]=real [bool]=boolean)

# ------------------------------------------------------------------------------
# @var _KNIT_BUILTIN_TYPES
#
# Set of built-in canonical type names.
# ------------------------------------------------------------------------------
declare -gA _KNIT_BUILTIN_TYPES
_KNIT_BUILTIN_TYPES=(
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
# @var _KNIT_ENUMS
#
# Set of user-defined enum type names.
# ------------------------------------------------------------------------------
declare -gA _KNIT_ENUMS

# ------------------------------------------------------------------------------
# @var _KNIT_BUILTIN_ENUMS
#
# Set of enum type names that have been marked as framework builtins (via
# _knit_is_builtin). Used to distinguish knit's own enums from user-defined ones.
# ------------------------------------------------------------------------------
declare -gA _KNIT_BUILTIN_ENUMS

# ------------------------------------------------------------------------------
# @var _KNIT_LAST_ENUM
#
# Name of the most recently defined enum (set by knit_define_enum). Consulted by
# _knit_is_builtin when called outside a command registration, so a builtin enum
# can be marked immediately after its definition.
# ------------------------------------------------------------------------------
declare -g _KNIT_LAST_ENUM
_KNIT_LAST_ENUM=''

# ------------------------------------------------------------------------------
# @fn _knit_type_resolve_alias()
#
# Resolve a type name or alias to its canonical type name. If the name is
# already a canonical built-in type or an enum, it is returned as-is. If it
# is an alias, the corresponding canonical name is printed.
#
# Example:
# ```
# local t; _knit_type_resolve_alias t "int"      # t == "integer"
# local t; _knit_type_resolve_alias t "integer"  # t == "integer"
# local t; _knit_type_resolve_alias t "color"    # t == "color" (if enum defined)
# ```
#
# @param __knit_ret Name of the variable to hold the resolved type name.
# @param type_name Type name or alias to resolve.
# @return 0 if resolved successfully, 1 if the name is unknown.
# ------------------------------------------------------------------------------
_knit_type_resolve_alias() {
    local -n __knit_ret=$1
    local name="$2"
    if [[ -v _KNIT_TYPE_ALIASES["${name}"] ]]; then
        __knit_ret="${_KNIT_TYPE_ALIASES[${name}]}"
        return 0
    fi
    if [[ -v _KNIT_BUILTIN_TYPES["${name}"] ]]; then
        __knit_ret="${name}"
        return 0
    fi
    if [[ -v _KNIT_ENUMS["${name}"] ]]; then
        __knit_ret="${name}"
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
    local __resolved
    _knit_type_resolve_alias __resolved "$1"
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
    _knit_set_add _KNIT_ENUMS "${name}"
    _KNIT_LAST_ENUM="${name}"
    _knit_set_new "_KNIT_ENUM_${name}"
    _knit_set_add "_KNIT_ENUM_${name}" "$@"
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
    local set_name="_KNIT_ENUM_${name}"
    if [[ ! -v _KNIT_ENUMS["${name}"] ]]; then
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
# @fn _knit_type_check_date()
#
# Validate that a string is a date in YYYY-MM-DD format with valid ranges.
#
# @param value String to validate.
# @return 0 if valid, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_type_check_date() {
    local value="$1"
    local date_re='^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
    [[ "${value}" =~ ${date_re} ]] || return 1
    local month=$((10#${BASH_REMATCH[2]}))
    local day=$((10#${BASH_REMATCH[3]}))
    (( month >= 1 && month <= 12 && day >= 1 && day <= 31 ))
}

# ------------------------------------------------------------------------------
# @fn _knit_type_check_time()
#
# Validate that a string is a time in hh:mm:ss format with valid ranges.
#
# @param value String to validate.
# @return 0 if valid, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_type_check_time() {
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
    _knit_type_resolve_alias resolved "${type}" || return 1

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
            _knit_type_check_date "${value}"
            ;;
        time)
            _knit_type_check_time "${value}"
            ;;
        datetime)
            [[ "${value}" =~ ${datetime_re} ]] || return 1
            local __date_part="${BASH_REMATCH[1]}"
            local __time_part="${BASH_REMATCH[2]}"
            _knit_type_check_date "${__date_part}" \
                && _knit_type_check_time "${__time_part}"
            ;;
        uuid)
            local uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            [[ "${value}" =~ ${uuid_re} ]]
            ;;
        *)
            # Enum type
            _knit_set_find "_KNIT_ENUM_${resolved}" "${value}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_type_to_sqlite()
#
# Map a Knit type name (or alias) to its corresponding SQLite type affinity.
# Returns INTEGER for integer, REAL for real, and TEXT for all other types
# (including boolean, string, path, file, filename, date, time, datetime, uuid,
# and user-defined enums).
#
# Example:
# ```
# local t; _knit_type_to_sqlite t "integer"  # t == INTEGER
# local t; _knit_type_to_sqlite t "real"     # t == REAL
# local t; _knit_type_to_sqlite t "uuid"     # t == TEXT
# local t; _knit_type_to_sqlite t "int"      # t == INTEGER (alias resolved)
# ```
#
# @param __knit_ret Name of the variable to hold the SQLite type affinity.
# @param type_name Knit type name or alias.
# @return 0 on success, 1 if the type is unknown.
# ------------------------------------------------------------------------------
_knit_type_to_sqlite() {
    local -n __knit_ret=$1
    local resolved
    _knit_type_resolve_alias resolved "$2" || return 1
    case "${resolved}" in
        integer) __knit_ret='INTEGER' ;;
        real)    __knit_ret='REAL' ;;
        *)       __knit_ret='TEXT' ;;
    esac
}
