#!/bin/bash

# ------------------------------------------------------------------------------
# Prepare for framed output. This function is used in _knit_framed and should
# not be used on its own.
#
# @param nlines Number of lines inside the frame.
# ------------------------------------------------------------------------------
__knit_framed_begin() {
    local nlines=$1
    local terminal
    terminal=$(tty)
    local ncolumns
    ncolumns=$(stty -a <"$terminal" | grep -Po '(?<=columns )\d+')
    ncolumns=$((ncolumns - 2))
    local i
    printf "\033[90m┌"
    for ((i = 0; i < ncolumns; i++)); do
        printf "─"
    done
    printf "┐\n"
    for ((i = 0; i < nlines; i++)); do
        printf "│%-${ncolumns}s│\n" ""
    done
    printf "└"
    for ((i = 0; i < ncolumns; i++)); do
        printf "─"
    done
    printf "┘\033[0m\n"
}

# ------------------------------------------------------------------------------
# Clear the frame. This function is used in _knit_framed and should not be used
# on its own.
#
# @param nlines Number of lines inside the frame.
# ------------------------------------------------------------------------------
__knit_frame_clear() {
    local nlines=$(($1 + 2))
    local i
    for ((i = 0; i < nlines; i++)); do
        printf "\033[1A" 1>&2 # move cursor one line up
        printf "\033[2K\r" 1>&2 # erase current line
    done
}

# ------------------------------------------------------------------------------
# Update the content of the frame. This function is used in _knit_framed and
# should not be used on its own. It will take the last nlines lines of the
# specified file and print them in the frame (truncated if they are too long).
#
# @param nlines Number of lines inside the frame.
# @param filename File with the content to print.
# @param header Header of the frame.
# ------------------------------------------------------------------------------
__knit_framed_update() {
    local nlines="$1"
    local filename="$2"
    local header="$3"
    local terminal
    terminal=$(tty)
    local ncolumns
    ncolumns=$(stty -a <"$terminal" | grep -Po '(?<=columns )\d+')
    ncolumns=$((ncolumns - 2))
    local output
    output=$(tail -n "${nlines}" "${filename}")

    local lines
    mapfile -t lines <<< "$output"

    __knit_frame_clear "${nlines}"

    local i
    local padlen=$((ncolumns - ${#header} - 3))
    printf "\033[90m┌── %s" "${header}"
    for ((i = 0; i < padlen; i++)); do
        printf "─"
    done
    printf "┐\n"
    for ((i = 0; i < nlines; i++)); do
        if [[ $i -lt ${#lines[@]} ]]; then
            printf "│%-${ncolumns}s│\n" "${lines[i]:0:${ncolumns}}"
        else
            printf "│%-${ncolumns}s│\n" ""
        fi
    done
    printf "└"
    for ((i = 0; i < ncolumns; i++)); do
        printf "─"
    done
    printf "┘\033[0m\n"
}

# ------------------------------------------------------------------------------
# Run a command and put a frame around its output, showing only the last 10
# lines of output and updating them as the command runs.
#
# @param ... Command to run, with its arguments.
# ------------------------------------------------------------------------------
_knit_framed() {
    local nlines=10
    local cmd=("$@")
    local temp_file
    temp_file=$(mktemp)
    local cmd_pid
    "${cmd[@]}" >"$temp_file" 2>&1 &
    cmd_pid=$!

    local spin=("─" "\\" "|" "/")

    __knit_framed_begin $nlines

    local i=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
        local header="${cmd[*]} ${spin[$((i % 4))]}"
        __knit_framed_update "${nlines}" "${temp_file}" "${header}"
        # shellcheck disable=SC2162
        read -t 0.1
        i=$((i+1))
    done
    __knit_frame_clear $nlines

    local exit_code
    wait "$cmd_pid"
    exit_code=$?

    rm -f "$temp_file"

    return $exit_code
}
