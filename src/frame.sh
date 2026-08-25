#!/bin/bash

## @file frame.sh

# ------------------------------------------------------------------------------
# @fn knit_framed()
#
# Piping a command's output into knit_framed will make the output appear inside
# a frame with the given height and width. If stdout is not a TTY, stdin is
# forwarded to stdout unchanged.
#
# Usage: `my-command arg1 arg2 ... | knit_framed [<height> [<width>]] [--title <title>] [--cleanup]`
#
# @param[in] height Height of the frame (default: terminal height).
# @param[in] width Width of the frame (default: terminal width).
# @param[in] --title Optional title displayed centered on the top border.
# @param[in] --cleanup If present, erase the frame from the screen after completion.
# @param[in] --frame-color Foreground color of the frame borders (key in _KNIT_COLORS).
# @param[in] --frame-bg-color Background color of the frame borders (key in _KNIT_COLORS).
# @param[in] --text-color Foreground color of the text inside the frame (key in _KNIT_COLORS).
# @param[in] --text-bg-color Background color of the text inside the frame (key in _KNIT_COLORS).
# @param[in] --log-level Minimum log level required to display the frame (trace, debug, info,
#                    warning, error, critical). If KNIT_LOG_LEVEL is above this level,
#                    stdin is drained silently and nothing is output.
# ------------------------------------------------------------------------------
knit_framed() {
    # Validate named arguments. The leading positional height/width (anything
    # before the first --option) are stripped first so only the named portion
    # is checked.
    local -a __named=("$@")
    while [[ ${#__named[@]} -gt 0 && "${__named[0]}" != --* ]]; do
        __named=("${__named[@]:1}")
    done
    knit_check_arguments \
        "title frame-color frame-bg-color text-color text-bg-color log-level" \
        "cleanup" \
        "${__named[@]}" || return 1

    local log_level
    log_level=$(knit_get_parameter "log-level" "$@") || log_level=""
    if [[ -n "$log_level" ]]; then
        case "$log_level" in
            trace|debug|info|warning|error|critical) ;;
            *)
                knit_warning "Unknown log level '%s' for --log-level; ignoring." "$log_level"
                log_level=""
                ;;
        esac
    fi
    local __cur_lvl __req_lvl
    _knit_log_level_to_int __cur_lvl "${KNIT_LOG_LEVEL}"
    _knit_log_level_to_int __req_lvl "$log_level"
    if [[ -n "$log_level" ]] && (( __cur_lvl > __req_lvl )); then
        cat > /dev/null
        return 0
    fi

    # Detect --cleanup before the TTY check so both paths can honour it.
    local cleanup=false
    local __arg
    for __arg in "$@"; do
        if [[ "$__arg" == "--cleanup" ]]; then
            cleanup=true
            break
        fi
    done
    unset __arg

    # If not running in a TTY, forward stdin to stdout unchanged.
    if [[ ! -t 1 ]]; then
        cat
        return 0
    fi

    local default_height
    local default_width
    IFS=' ' read -r default_height default_width < <(stty size </dev/tty 2>/dev/null || echo "24 80")
    default_height=$((default_height / 2))

    local height=${1:-$default_height}
    local width=${2:-$default_width}
    local title
    title=$(knit_get_parameter "title" "$@") || title=""

    local frame_color frame_bg_color text_color text_bg_color
    frame_color=$(knit_get_parameter    "frame-color"    "$@") || frame_color=""
    frame_bg_color=$(knit_get_parameter "frame-bg-color" "$@") || frame_bg_color=""
    text_color=$(knit_get_parameter     "text-color"     "$@") || text_color=""
    text_bg_color=$(knit_get_parameter  "text-bg-color"  "$@") || text_bg_color=""

    local __c
    for __c in frame_color frame_bg_color text_color text_bg_color; do
        if [[ -n "${!__c}" ]] && [[ ! -v "_KNIT_COLORS[${!__c}]" ]]; then
            knit_warning "Unknown color '%s' for --%s; ignoring." "${!__c}" "${__c//_/-}"
            printf -v "$__c" ""
        fi
    done
    unset __c

    local frame_esc=""
    [[ -n "$frame_color"    ]] && frame_esc+="${_KNIT_COLORS[$frame_color]}"
    [[ -n "$frame_bg_color" ]] && frame_esc+="${_KNIT_COLORS[$frame_bg_color]}"
    local text_esc=""
    [[ -n "$text_color"    ]] && text_esc+="${_KNIT_COLORS[$text_color]}"
    [[ -n "$text_bg_color" ]] && text_esc+="${_KNIT_COLORS[$text_bg_color]}"
    local reset=""
    [[ -n "$frame_esc" || -n "$text_esc" ]] && reset="${_KNIT_COLORS[reset]}"

    if [[ "$height" == "-1" ]]; then
        height=$default_height
    elif ! [[ "$height" =~ ^[0-9]+$ ]] || (( height < 3 )); then
        knit_warning "Invalid frame height '%s'; using terminal default (%d)." "${height}" "${default_height}"
        height=$default_height
    fi

    if [[ "$width" == "-1" ]]; then
        width=$default_width
    elif ! [[ "$width" =~ ^[0-9]+$ ]] || (( width < 3 )); then
        knit_warning "Invalid frame width '%s'; using terminal default (%d)." "${width}" "${default_width}"
        width=$default_width
    fi

    local inner_width=$(( width - 2 ))
    local inner_height=$(( height - 2 ))
    local -a buffer=()

    # --------------------------------------------------------------------------
    # @fn _knit_draw_frame()
    #
    # Redraws the frame in place by moving the cursor up and overwriting.
    # Reads from the outer function's `buffer`, `inner_width`, and
    # `inner_height` variables.
    # --------------------------------------------------------------------------
    _knit_draw_frame() {
        # Move cursor up to overwrite old frame.
        printf "\033[%dA" "$height" 2>/dev/null || true

        # Top border — optionally with a centered title.
        printf '%s┌' "$frame_esc"
        local max_title=$(( inner_width - 4 ))  # 2 spaces + min 2 dashes
        if [[ -n "$title" ]] && (( max_title >= 1 )); then
            local t="$title"
            if (( ${#t} > max_title )); then
                t="${t:0:$(( max_title - 3 ))}..."
            fi
            local display=" ${t} "
            local remaining=$(( inner_width - ${#display} ))
            local left=$(( remaining / 2 ))
            local right=$(( remaining - left ))
            printf -- '─%.0s' $(seq 1 "$left")
            printf '%s' "${display}"
            printf -- '─%.0s' $(seq 1 "$right")
        else
            printf -- '─%.0s' $(seq 1 "$inner_width")
        fi
        printf '┐%s\n' "$reset"

        # Inner rows — show the last inner_height lines of the buffer.
        local start=$(( ${#buffer[@]} > inner_height ? ${#buffer[@]} - inner_height : 0 ))
        local line
        for ((i = start; i < ${#buffer[@]}; i++)); do
            line="${buffer[i]}"
            if (( ${#line} > inner_width )); then
                line="${line:0:inner_width}"
            fi
            printf '%s│%s%-*s%s%s│%s\n' \
                "$frame_esc" "$text_esc" "$inner_width" "$line" "$reset" "$frame_esc" "$reset"
        done

        # Pad remaining rows with empty lines.
        for ((i = ${#buffer[@]}; i < inner_height; i++)); do
            printf '%s│%s%*s%s%s│%s\n' \
                "$frame_esc" "$text_esc" "$inner_width" "" "$reset" "$frame_esc" "$reset"
        done

        # Bottom border.
        printf '%s└' "$frame_esc"
        printf -- '─%.0s' $(seq 1 "$inner_width")
        printf '┘%s\n' "$reset"
    }

    # Print blank lines so the initial draw_frame has room to move back up.
    for ((i = 0; i < height; i++)); do echo; done

    _knit_draw_frame

    # Stream input line by line, redrawing after each.
    while IFS= read -r line; do
        buffer+=("$line")
        _knit_draw_frame
    done

    if [[ "$cleanup" == "true" ]]; then
        printf "\033[%dA" "$height"
        printf '\033[J'
    fi
}
