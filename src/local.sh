#!/bin/bash

## @file local.sh

# ------------------------------------------------------------------------------
# @fn __knit_walltime_to_seconds()
#
# Convert a wall-clock time string in HH:MM:SS format to an integer number of
# seconds.
#
# @param walltime Wall-clock time in HH:MM:SS format.
# ------------------------------------------------------------------------------
__knit_walltime_to_seconds() {
    local walltime="$1"
    local h m s
    IFS=: read -r h m s <<< "${walltime}"
    printf '%d' "$(( 10#${h} * 3600 + 10#${m} * 60 + 10#${s} ))"
}

# ------------------------------------------------------------------------------
# @fn _knit_submit_local()
#
# Submit a command as a background process, acting as a minimal local job
# scheduler for development and testing on machines without an HPC scheduler.
#
# The process is launched with nohup so it survives terminal disconnects.
# nohup exec-replaces itself with the target command without forking, so the
# returned PID refers directly to the running command process.
#
# Prints the PID of the background process on stdout and returns 0.
# Returns 1 on argument errors.
#
# Everything after a literal -- is the command (and its arguments) to run and
# is not validated as a submission option. Options may be given either as
# "--name value" or "--name=value".
#
# @param ... Submission options followed by -- and the command to run:
#   --stdout <file>      Redirect command stdout to <file>  (default: /dev/null)
#   --stderr <file>      Redirect command stderr to <file>  (default: /dev/null)
#   --stdin  <file>      Redirect command stdin from <file> (default: /dev/null)
#   --walltime HH:MM:SS  Kill the command after this wall-clock time.
# ------------------------------------------------------------------------------
_knit_submit_local() {
    local -a args=("$@")
    knit_check_arguments "stdout stderr stdin walltime" "" "${args[@]}" || return 1

    local stdout_file="" stderr_file="" stdin_file="" walltime=""
    stdout_file="$(knit_get_parameter "stdout"   "${args[@]}")" || stdout_file=""
    stderr_file="$(knit_get_parameter "stderr"   "${args[@]}")" || stderr_file=""
    stdin_file="$(knit_get_parameter  "stdin"    "${args[@]}")" || stdin_file=""
    walltime="$(knit_get_parameter    "walltime" "${args[@]}")" || walltime=""

    local extra_index
    extra_index="$(knit_extra_index "${args[@]}")"
    local -a cmd=("${args[@]:extra_index}")

    if [[ ${#cmd[@]} -eq 0 ]]; then
        knit_error "_knit_submit_local: no command specified after --"
        return 1
    fi

    if [[ -n "${walltime}" && ! "${walltime}" =~ ^[0-9]{1,3}:[0-5][0-9]:[0-5][0-9]$ ]]; then
        knit_error "_knit_submit_local: invalid walltime: ${walltime} (expected HH:MM:SS)"
        return 1
    fi

    local stdin_redir="/dev/null"
    local stdout_redir="/dev/null"
    local stderr_redir="/dev/null"
    [[ -n "${stdin_file}" ]]  && stdin_redir="${stdin_file}"
    [[ -n "${stdout_file}" ]] && stdout_redir="${stdout_file}"
    [[ -n "${stderr_file}" ]] && stderr_redir="${stderr_file}"

    local -a full_cmd=()
    if [[ -n "${walltime}" ]]; then
        local timeout_secs
        timeout_secs="$(__knit_walltime_to_seconds "${walltime}")"
        full_cmd=(timeout "${timeout_secs}" "${cmd[@]}")
    else
        full_cmd=("${cmd[@]}")
    fi

    # nohup ignores SIGHUP (survives terminal disconnect) and exec-replaces
    # itself with the command without forking, so $! is the PID of the running
    # command rather than a wrapper process.
    nohup "${full_cmd[@]}" \
        < "${stdin_redir}" \
        > "${stdout_redir}" \
        2>> "${stderr_redir}" &
    printf '%s\n' "$!"
}

# ------------------------------------------------------------------------------
# @fn _knit_wait_local()
#
# Wait until a locally submitted background process has finished.
#
# Uses kill -0 polling because wait(1) only works for child processes of the
# current shell, and _knit_submit_local detaches the process via nohup.
#
# @param pid PID returned by _knit_submit_local.
# ------------------------------------------------------------------------------
_knit_wait_local() {
    local pid="$1"
    if [[ -z "${pid}" || ! "${pid}" =~ ^[0-9]+$ ]]; then
        knit_error "_knit_wait_local: invalid PID: ${pid}"
        return 1
    fi
    while kill -0 "${pid}" 2>/dev/null; do
        sleep 1
    done
}
