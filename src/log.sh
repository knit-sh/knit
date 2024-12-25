#!/bin/bash

_KNIT_LOG_LEVEL=2

# ------------------------------------------------------------------------------
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
        if [[ "$level" == "${valid_levels[i]}" ]]; then
            _KNIT_LOG_LEVEL=$i
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------------------
# This function acts like echo but takes a log level first, and adds
# [knit:<level>] in front and \n after the text.
#
# Example:
# ```
# knit_log info "Hello, "Matthieu"
# ```
#
# @param level Logging level.
# @param ... Arguments for echo.
# ------------------------------------------------------------------------------
_knit_log() {
    local level=$1
    shift
    echo "[knit:$level] $@"
}

# ------------------------------------------------------------------------------
# Logging function for trace-level messages. Works like echo but will only
# print if the logging level was set to "trace".
#
# @param ... Arguments for echo.
# ------------------------------------------------------------------------------
knit_trace() {
    if ((_KNIT_LOG_LEVEL <= 0)); then
        _knit_log trace $@
    fi
}

# ------------------------------------------------------------------------------
# Logging function for debug-level messages. Works like echo but will only
# print if the logging level was set to "debug".
#
# @param ... Arguments for echo.
# ------------------------------------------------------------------------------
knit_debug() {
    if ((_KNIT_LOG_LEVEL <= 1)); then
        _knit_log debug $@
    fi
}

# ------------------------------------------------------------------------------
# Logging function for info-level messages. Works like echo but will only
# print if the logging level was set to "info".
#
# @param ... Arguments for echo.
# ------------------------------------------------------------------------------
knit_info() {
    if ((_KNIT_LOG_LEVEL <= 2)); then
        _knit_log info $@
    fi
}

# ------------------------------------------------------------------------------
# Logging function for warning-level messages. Works like echo but will only
# print if the logging level was set to "warning".
#
# @param ... Arguments for echo.
# ------------------------------------------------------------------------------
knit_warning() {
    if ((_KNIT_LOG_LEVEL <= 3)); then
        _knit_log warning $@
    fi
}

# ------------------------------------------------------------------------------
# Logging function for error-level messages. Works like echo but will only
# print if the logging level was set to "error".
#
# @param ... Arguments for echo.
# ------------------------------------------------------------------------------
knit_error() {
    if ((_KNIT_LOG_LEVEL <= 4)); then
        _knit_log error $@
    fi
}

# ------------------------------------------------------------------------------
# Logging function for critical-level messages. Works like echo but will only
# print if the logging level was set to "critical".
#
# @param ... Arguments for echo.
# ------------------------------------------------------------------------------
knit_critical() {
    if ((_KNIT_LOG_LEVEL <= 5)); then
        _knit_log critical $@
    fi
}

# ------------------------------------------------------------------------------
# Logging function for fatal error messages. Will be printed no matter the log
# level, and the program will exit with an error value.
#
# @param ... Arguments for echo.
# ------------------------------------------------------------------------------
knit_fatal() {
    _knit_log fatal $@
    exit 1
}
