#!/bin/bash

## @file log.sh

# ------------------------------------------------------------------------------
# @var KNIT_LOG_LEVEL
#
# Log level. Valid values: trace, debug, info, warning, error, critical.
# ------------------------------------------------------------------------------
declare -x KNIT_LOG_LEVEL
KNIT_LOG_LEVEL=${KNIT_LOG_LEVEL:-info}

# ------------------------------------------------------------------------------
# @fn _knit_log_level_to_int()
#
# Convert a log level string to its integer value, storing it in the
# caller-named variable. trace=0, debug=1, info=2, warning=3, error=4,
# critical=5. Yields 2 (info) for unrecognized values.
#
# @param __knit_ret Name of the variable to hold the integer value.
# @param level Log level string.
# ------------------------------------------------------------------------------
_knit_log_level_to_int() {
    local -n __knit_ret=$1
    case "$2" in
        trace)    __knit_ret=0 ;;
        debug)    __knit_ret=1 ;;
        info)     __knit_ret=2 ;;
        warning)  __knit_ret=3 ;;
        error)    __knit_ret=4 ;;
        critical) __knit_ret=5 ;;
        *)        __knit_ret=2 ;;
    esac
}

# ------------------------------------------------------------------------------
# The trace file is the file used to redirect the output of programs. It is
# created lazily by _knit_ensure_trace_file() on first use rather than eagerly
# here: creating it at source time ran an mktemp on every "source knit.sh" and
# leaked a temporary file each time (the test suite sources knit.sh hundreds of
# times). Empty until first needed.
# ------------------------------------------------------------------------------
declare _KNIT_TRACE_FILE
_KNIT_TRACE_FILE=""

# ------------------------------------------------------------------------------
# @fn _knit_ensure_trace_file()
#
# Create the trace file on first use and cache its path in _KNIT_TRACE_FILE.
# Must be called in the current shell (not a subshell) before reading
# _KNIT_TRACE_FILE.
# ------------------------------------------------------------------------------
_knit_ensure_trace_file() {
    if [[ -z "${_KNIT_TRACE_FILE}" ]]; then
        _KNIT_TRACE_FILE="$(mktemp "${TMPDIR:-/tmp}/knit.out.XXXXXX")"
    fi
}

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
    printf "[knit:%s] " "$level" 1>&2
    # shellcheck disable=SC2059 # forwarding arguments to printf
    printf "${@}" 1>&2
    printf "\n" 1>&2
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
    local __lvl
    _knit_log_level_to_int __lvl "${KNIT_LOG_LEVEL}"
    if (( __lvl <= 0 )); then
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
    local __lvl
    _knit_log_level_to_int __lvl "${KNIT_LOG_LEVEL}"
    if (( __lvl <= 1 )); then
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
    local __lvl
    _knit_log_level_to_int __lvl "${KNIT_LOG_LEVEL}"
    if (( __lvl <= 2 )); then
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
    local __lvl
    _knit_log_level_to_int __lvl "${KNIT_LOG_LEVEL}"
    if (( __lvl <= 3 )); then
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
    local __lvl
    _knit_log_level_to_int __lvl "${KNIT_LOG_LEVEL}"
    if (( __lvl <= 4 )); then
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
    local __lvl
    _knit_log_level_to_int __lvl "${KNIT_LOG_LEVEL}"
    if (( __lvl <= 5 )); then
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
    # Only point at the trace file when it actually holds captured output. A
    # purely internal (logic) fatal writes nothing there, so the old
    # unconditional pointer — which also force-created the file — sent users to an
    # empty file. Subprocess failures create and fill it before fataling, so the
    # pointer still shows for the cases where it helps.
    if [[ -n "${_KNIT_TRACE_FILE}" && -s "${_KNIT_TRACE_FILE}" ]]; then
        _knit_log fatal "More info may be found in %s" "${_KNIT_TRACE_FILE}"
    fi
    exit 1
}

case "${KNIT_LOG_LEVEL}" in
    trace|debug|info|warning|error|critical) ;;
    *)
        knit_warning "KNIT_LOG_LEVEL=\"%s\" is not valid, resetting to \"info\"." "${KNIT_LOG_LEVEL}"
        KNIT_LOG_LEVEL=info
        ;;
esac
