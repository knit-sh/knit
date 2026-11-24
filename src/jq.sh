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
# @param[in] title Title shown on the frame's top border.
# @param[in] ... Command and arguments to execute.
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
# Make a jq program available at _KNIT_JQ_EXE. By default the prebuilt jq binary
# for the current platform is downloaded into the .knit directory, so the install
# is self-contained: an HPC compute node often differs from the login node (a
# login-only system jq, or a symlink to one, is absent or dangling there), so a
# downloaded binary is the portable default. With use_system the system jq is
# symlinked instead when one is on PATH, falling back to a download when none is
# found.
#
# @param[in] use_system When "true", symlink the system jq if one is on PATH
#        instead of downloading.
# ------------------------------------------------------------------------------
_knit_bootstrap_jq() {
    local use_system="${1:-false}"
    local system_jq=""
    if [[ "${use_system}" == "true" ]]; then
        system_jq="$(_knit_command_path jq)"
    fi

    if [[ -n "${system_jq}" ]]; then
        knit_info "Using system jq at ${system_jq} (symlinked)."
        mkdir -p "$(dirname "${_KNIT_JQ_EXE}")"
        ln -s "${system_jq}" "${_KNIT_JQ_EXE}"
    else
        _knit_download_jq
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_update_jq()
#
# Update-mode handler for --use-system-jq. The flag matters only when the current
# jq install is a downloaded binary and a system jq is on PATH: it replaces the
# download with a symlink to the system binary. An install that is already a
# system symlink is what the flag asks for, so it is a no-op; so is an untyped
# flag or an absent system binary.
#
# @param[in] ... Raw argument tokens of this invocation (see
#            _KNIT_INVOCATION_RAW_ARGS), used to tell a typed flag from a
#            defaulted one.
# @return 0 when jq was switched to a system symlink, 1 when nothing changed.
# ------------------------------------------------------------------------------
_knit_bootstrap_update_jq() {
    _knit_arg_was_provided "use-system-jq" "$@" || return 1
    [[ -L "${_KNIT_JQ_EXE}" ]] && return 1
    local system_jq; system_jq="$(_knit_command_path jq)"
    [[ -n "${system_jq}" ]] || return 1
    knit_info "Using system jq at ${system_jq} (symlinked)."
    rm -f "${_KNIT_JQ_EXE}"
    mkdir -p "$(dirname "${_KNIT_JQ_EXE}")"
    ln -s "${system_jq}" "${_KNIT_JQ_EXE}"
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_download_jq()
#
# Download the prebuilt jq binary for the current platform and install it in
# the .knit directory.
# ------------------------------------------------------------------------------
_knit_download_jq() {
    local platform
    platform=$(_knit_jq_platform)
    local url="https://github.com/jqlang/jq/releases/download/jq-${_KNIT_JQ_VERSION}/${platform}"
    knit_trace "Downloading jq binary (${platform})..."
    mkdir -p "$(dirname "${_KNIT_JQ_EXE}")"
    # -f turns a rate-limited/error GitHub response into a clean failure rather
    # than a saved error body; --retry rides out a transient network error; a
    # GITHUB_TOKEN/GH_TOKEN, when set, lifts the anonymous rate limit CI shares.
    local -a curl_args=(-fL --retry 3 --retry-delay 2 -o "${_KNIT_JQ_EXE}")
    local gh_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    [[ -n "${gh_token}" ]] && curl_args+=(-H "Authorization: Bearer ${gh_token}")
    if ! _knit_jq_framed_run "jq: download" \
            curl "${curl_args[@]}" "${url}" ; then
        knit_fatal "Could not download jq binary. See ${_KNIT_TRACE_FILE} for more information."
    fi
    chmod +x "${_KNIT_JQ_EXE}"
    knit_trace "jq installed at ${_KNIT_JQ_EXE}."
}

# shellcheck disable=SC2120
# ------------------------------------------------------------------------------
# @fn knit_jq()
#
# Invoke the jq that knit provisions. Public so a plugin runs the same pinned
# jq that the rest of knit uses rather than a jq on PATH.
#
# @param[in] ... Parameters to forward to the jq command.
# ------------------------------------------------------------------------------
knit_jq() {
    "${_KNIT_JQ_EXE}" "$@"
}
