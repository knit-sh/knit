#!/bin/bash

## @file jq.sh

# ------------------------------------------------------------------------------
# Version of jq to download.
# ------------------------------------------------------------------------------
_KNIT_JQ_VERSION="1.7.1"

# ------------------------------------------------------------------------------
# Path to the jq executable.
# ------------------------------------------------------------------------------
_KNIT_JQ_EXE="${_KNIT_PREFIX}/jq/bin/jq"

# ------------------------------------------------------------------------------
# @fn _knit_jq_platform()
#
# Prints the platform suffix for the jq prebuilt binary, e.g. "jq-linux-amd64".
# ------------------------------------------------------------------------------
_knit_jq_platform() {
    local os arch
    case "$(uname -s)" in
        Linux)  os="linux"  ;;
        Darwin) os="macos"  ;;
        *) knit_fatal "Unsupported OS for jq bootstrap: $(uname -s)." ;;
    esac
    case "$(uname -m)" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv6l) arch="armhf" ;;
        i386|i686)     arch="i386"  ;;
        *) knit_fatal "Unsupported architecture for jq bootstrap: $(uname -m)." ;;
    esac
    printf "jq-%s-%s" "${os}" "${arch}"
}

# ------------------------------------------------------------------------------
# @fn _knit_jq_framed_run()
#
# Run a command with its combined stdout/stderr written to _KNIT_TRACE_FILE and,
# when KNIT_LOG_LEVEL is trace, also displayed live in a 10-line frame.
# Returns the exit status of the command.
#
# @param title Title shown on the frame's top border.
# @param ... Command and arguments to execute.
# ------------------------------------------------------------------------------
_knit_jq_framed_run() {
    local title="$1"
    shift
    _knit_ensure_trace_file
    "$@" 2>&1 | tee "${_KNIT_TRACE_FILE}" | \
        knit_framed 10 -1 --title "${title}" --log-level trace --cleanup
    local -a pipe_status=("${PIPESTATUS[@]}")
    return "${pipe_status[0]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_jq()
#
# Download the prebuilt jq binary for the current platform and install it in
# the .knit directory.
# ------------------------------------------------------------------------------
_knit_bootstrap_jq() {
    local platform
    platform=$(_knit_jq_platform)
    local url="https://github.com/jqlang/jq/releases/download/jq-${_KNIT_JQ_VERSION}/${platform}"
    knit_trace "Downloading jq binary (${platform})..."
    mkdir -p "$(dirname "${_KNIT_JQ_EXE}")"
    if ! _knit_jq_framed_run "jq: download" \
            curl -L -o "${_KNIT_JQ_EXE}" "${url}" ; then
        knit_fatal "Could not download jq binary. See ${_KNIT_TRACE_FILE} for more information."
    fi
    chmod +x "${_KNIT_JQ_EXE}"
    knit_trace "jq installed at ${_KNIT_JQ_EXE}."
}

# shellcheck disable=SC2120
# ------------------------------------------------------------------------------
# @fn _knit_jq()
#
# Invoke Knit's jq installation.
#
# @param ... Parameters to forward to the jq command.
# ------------------------------------------------------------------------------
_knit_jq() {
    "${_KNIT_JQ_EXE}" "$@"
}
