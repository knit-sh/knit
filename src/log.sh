#!/bin/bash

## @file log.sh

# ------------------------------------------------------------------------------
# Log level. Valid values: trace, debug, info, warning, error, critical.
# ------------------------------------------------------------------------------
declare -x KNIT_LOG_LEVEL
KNIT_LOG_LEVEL=${KNIT_LOG_LEVEL:-info}

# ------------------------------------------------------------------------------
# @fn __knit_log_level_to_int()
#
# Convert a log level string to its integer value.
# trace=0, debug=1, info=2, warning=3, error=4, critical=5.
# Returns 2 (info) for unrecognized values.
#
# @param level Log level string.
# ------------------------------------------------------------------------------
__knit_log_level_to_int() {
    case "$1" in
        trace)    printf 0 ;;
        debug)    printf 1 ;;
        info)     printf 2 ;;
        warning)  printf 3 ;;
        error)    printf 4 ;;
        critical) printf 5 ;;
        *)        printf 2 ;;
    esac
}

# ------------------------------------------------------------------------------
# The trace file is the file used to redirect the output of programs.
# ------------------------------------------------------------------------------
declare _KNIT_TRACE_FILE
_KNIT_TRACE_FILE="$(mktemp /tmp/knit.out.XXXXXX)"

# ------------------------------------------------------------------------------
# @fn knit_log_set_level()
#
# Set the log level.
# The level should be either trace, debug, info, warning, error, or critical.
#
# @param level Log level.
# @return 0 if the log level was set, 1 otherwise.
# ------------------------------------------------------------------------------
knit_log_set_level() {
    local level="$1"
    case "${level}" in
        trace|debug|info|warning|error|critical)
            KNIT_LOG_LEVEL="${level}"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_log()
#
# This function acts like printf but takes a log level first, and adds
# [knit:<level>] in front and \n after the text. It outputs to stderr.
#
# Example:
# ```
# _knit_log info "Hello, Matthieu"
# ```
#
# @param level Logging level.
# @param ... Arguments for printf.
# ------------------------------------------------------------------------------
_knit_log() {
    local level="$1";
    shift
    printf "[knit:%s]] " "$level" 1>&2
    # shellcheck disable=SC2059 # forwarding arguments to printf
    printf "${@}" 1>&2
    printf "\n"
}

# ------------------------------------------------------------------------------
# @fn knit_trace()
#
# Logging function for trace-level messages. Works like echo but will only
# print if the logging level was set to "trace".
#
# @param ... Arguments for printf.
# ------------------------------------------------------------------------------
knit_trace() {
    if (( $(__knit_log_level_to_int "${KNIT_LOG_LEVEL}") <= 0 )); then
        _knit_log trace "$@"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_debug()
#
# Logging function for debug-level messages. Works like echo but will only
# print if the logging level was set to "debug".
#
# @param ... Arguments for printf.
# ------------------------------------------------------------------------------
knit_debug() {
    if (( $(__knit_log_level_to_int "${KNIT_LOG_LEVEL}") <= 1 )); then
        _knit_log debug "$@"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_info()
#
# Logging function for info-level messages. Works like echo but will only
# print if the logging level was set to "info".
#
# @param ... Arguments for printf.
# ------------------------------------------------------------------------------
knit_info() {
    if (( $(__knit_log_level_to_int "${KNIT_LOG_LEVEL}") <= 2 )); then
        _knit_log info "$@"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_warning()
#
# Logging function for warning-level messages. Works like echo but will only
# print if the logging level was set to "warning".
#
# @param ... Arguments for printf.
# ------------------------------------------------------------------------------
knit_warning() {
    if (( $(__knit_log_level_to_int "${KNIT_LOG_LEVEL}") <= 3 )); then
        _knit_log warning "$@"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_error()
#
# Logging function for error-level messages. Works like echo but will only
# print if the logging level was set to "error".
#
# @param ... Arguments for printf.
# ------------------------------------------------------------------------------
knit_error() {
    if (( $(__knit_log_level_to_int "${KNIT_LOG_LEVEL}") <= 4 )); then
        _knit_log error "$@"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_critical()
#
# Logging function for critical-level messages. Works like echo but will only
# print if the logging level was set to "critical".
#
# @param ... Arguments for printf.
# ------------------------------------------------------------------------------
knit_critical() {
    if (( $(__knit_log_level_to_int "${KNIT_LOG_LEVEL}") <= 5 )); then
        _knit_log critical "$@"
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_fatal()
#
# Logging function for fatal error messages. Will be printed no matter the log
# level, and the program will exit with an error value.
#
# @param ... Arguments for printf.
# ------------------------------------------------------------------------------
knit_fatal() {
    _knit_log fatal "$@"
    _knit_log fatal "More info may be found in %s" "$_KNIT_TRACE_FILE"
    exit 1
}

case "${KNIT_LOG_LEVEL}" in
    trace|debug|info|warning|error|critical) ;;
    *)
        knit_warning "KNIT_LOG_LEVEL=\"%s\" is not valid, resetting to \"info\"." "${KNIT_LOG_LEVEL}"
        KNIT_LOG_LEVEL=info
        ;;
esac
