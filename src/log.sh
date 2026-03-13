#!/bin/bash

## @file log.sh

KNIT_LOG_LEVEL=${KNIT_LOG_LEVEL:-2}
_KNIT_TRACE_FILE=("$(mktemp /tmp/knit.out.XXXXXX)")

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
    local valid_levels=("trace" "debug" "info" "warning" "error" "critical")
    local i
    for i in "${!valid_levels[@]}"; do
        if [[ "${level}" == "${valid_levels[i]}" ]]; then
            KNIT_LOG_LEVEL=$i
            return 0
        fi
    done
    return 1
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
    local level="$1"
    shift
    printf "[knit:$level] " 1>&2
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
    if ((KNIT_LOG_LEVEL <= 0)); then
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
    if ((KNIT_LOG_LEVEL <= 1)); then
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
    if ((KNIT_LOG_LEVEL <= 2)); then
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
    if ((KNIT_LOG_LEVEL <= 3)); then
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
    if ((KNIT_LOG_LEVEL <= 4)); then
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
    if ((KNIT_LOG_LEVEL <= 5)); then
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
    exit 1
}
