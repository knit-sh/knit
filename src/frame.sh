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

# ------------------------------------------------------------------------------
# @fn knit_framed_run()
#
# Run a command with its combined stdout/stderr written to _KNIT_TRACE_FILE and,
# when KNIT_LOG_LEVEL is trace, also displayed live in a 10-line frame. Returns
# the exit status of the command. Used by every subsystem that provisions or
# fetches over the network (Spack provisioning, plugin import, knit_github_download);
# public so a plugin can frame its own long steps the same way.
#
# @param[in] title Title shown on the frame's top border.
# @param[in] ... Command and arguments to execute.
# @return The exit status of the command.
# ------------------------------------------------------------------------------
knit_framed_run() {
    local title="$1"
    shift
    _knit_ensure_trace_file
    "$@" 2>&1 | tee "${_KNIT_TRACE_FILE}" | \
        knit_framed 10 -1 --title "${title}" --log-level trace --cleanup
    local -a pipe_status=("${PIPESTATUS[@]}")
    return "${pipe_status[0]}"
}

# ------------------------------------------------------------------------------
# Progress bar
#
# A full-width, framed progress bar for long, batch-of-jobs commands (submit
# drain, ax optimize). The bar interior fills left to right with one run of block
# cells per section, in the order failed | completed | running | remaining, with
# the remaining portion left as whitespace inside the frame. Failed sits first so
# a failure is the first thing the eye lands on. Section colors are knit brand
# accents (magenta / dark purple / light purple) with a 16-color fallback.
#
# The surface is split into pure string renderers (no terminal I/O, below) and a
# TTY draw layer (knit_progress_bar / knit_progress_bar2, added separately). The
# renderers take an explicit width and an explicit --no-color so they are
# deterministic and unit-testable; the draw layer owns the terminal.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @var _KNIT_PROGRESS_FULL
#
# Full block glyph (U+2588) for the completed and failed progress-bar sections;
# color distinguishes the two.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROGRESS_FULL
_KNIT_PROGRESS_FULL=$'█'

# ------------------------------------------------------------------------------
# @var _KNIT_PROGRESS_RUN
#
# Medium-shade block glyph (U+2592) for the running progress-bar section, so it is
# distinct from the completed section even without color.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROGRESS_RUN
_KNIT_PROGRESS_RUN=$'▒'

# ------------------------------------------------------------------------------
# @fn _knit_progress_bar_render()
#
# Build the interior fill string for one bar row of exactly <width> display cells
# and return it by nameref. No frame, no counts, no terminal I/O. Section order is
# failed | completed | running | remaining(space); whole cells only (no partial
# blocks). Cell counts use largest-remainder rounding so the runs sum to exactly
# <width>, and a non-zero section keeps at least one cell while the field has room
# (a single failed/running job is always visible). Colors are the brand accents
# via _knit_brand_color; with --no-color the glyphs become ASCII (# for
# failed/completed, : for running, space for remaining).
#
# @param[out] __knit_ret Name of the variable to receive the fill string.
# @param[in] width Interior width in cells.
# @param[in] completed Number of completed items.
# @param[in] running Number of running items.
# @param[in] failed Number of failed/killed items.
# @param[in] remaining Number of not-yet-started items.
# @param[in] --no-color Optional: emit ASCII glyphs and no color escapes.
# ------------------------------------------------------------------------------
_knit_progress_bar_render() {
    local -n __knit_ret=$1
    shift
    local width=$1 completed=$2 running=$3 failed=$4 remaining=$5
    shift 5
    local nocolor=false
    [[ "${1:-}" == "--no-color" ]] && nocolor=true

    local total=$(( completed + running + failed + remaining ))
    if (( total <= 0 )); then
        printf -v __knit_ret '%*s' "${width}" ''
        return 0
    fi

    # Whole-cell width per filled section (remaining takes whatever is left over).
    local fcells ccells rcells
    fcells=$(( failed * width / total ))
    ccells=$(( completed * width / total ))
    rcells=$(( running * width / total ))
    # A non-zero section shows at least one cell, when the field has the room.
    (( failed > 0 && fcells == 0 )) && fcells=1
    (( completed > 0 && ccells == 0 )) && ccells=1
    (( running > 0 && rcells == 0 )) && rcells=1
    # If the minimum-one-cell promotion pushed the fill over the field, trim back
    # (failed yields first, then completed, then running) so it never exceeds width.
    local overflow=$(( fcells + ccells + rcells - width ))
    if (( overflow > 0 )); then
        local name
        for name in fcells ccells rcells; do
            (( overflow <= 0 )) && break
            local -n __ref=${name}
            local slack=$(( __ref - 1 ))
            (( slack < 0 )) && slack=0
            local take=$(( slack < overflow ? slack : overflow ))
            __ref=$(( __ref - take ))
            overflow=$(( overflow - take ))
        done
    fi

    local reset="" gfull grun
    if [[ "${nocolor}" == true ]]; then
        gfull='#'
        grun=':'
    else
        gfull="${_KNIT_PROGRESS_FULL}"
        grun="${_KNIT_PROGRESS_RUN}"
        reset="${_KNIT_COLORS[reset]}"
    fi

    # Build the three colored runs, then the blank remainder track. The buffer is
    # named with the nameref-safe __ prefix so it cannot shadow a caller outvar.
    # Parallel arrays (not a packed ":"-separated string) because a glyph may itself
    # be ":" in the no-color case.
    local __knit_fill=""
    local -a sec_n=("${fcells}" "${ccells}" "${rcells}")
    local -a sec_brand=(magenta purple_dark purple)
    local -a sec_glyph=("${gfull}" "${gfull}" "${grun}")
    local i
    for (( i = 0; i < 3; i++ )); do
        local n="${sec_n[i]}"
        (( n <= 0 )) && continue
        local run="" k
        for (( k = 0; k < n; k++ )); do run+="${sec_glyph[i]}"; done
        if [[ -n "${reset}" ]]; then
            local on=""
            _knit_brand_color on "${sec_brand[i]}"
            run="${on}${run}${reset}"
        fi
        __knit_fill+="${run}"
    done

    local blanks=$(( width - fcells - ccells - rcells ))
    (( blanks < 0 )) && blanks=0
    (( blanks > 0 )) && printf -v __knit_fill '%s%*s' "${__knit_fill}" "${blanks}" ''

    __knit_ret="${__knit_fill}"
}

# ------------------------------------------------------------------------------
# @fn _knit_progress_bar_legend()
#
# Build the one-line glyph key drawn under the frame and return it by nameref. The
# order matches the bar: failed, done, running. With --no-color the glyphs are
# ASCII (failed and done both render as #, so the legend labels carry the
# distinction).
#
# @param[out] __knit_ret Name of the variable to receive the legend string.
# @param[in] --no-color Optional: emit ASCII glyphs and no color escapes.
# ------------------------------------------------------------------------------
_knit_progress_bar_legend() {
    local -n __knit_ret=$1
    shift
    local nocolor=false
    [[ "${1:-}" == "--no-color" ]] && nocolor=true

    if [[ "${nocolor}" == true ]]; then
        printf -v __knit_ret '  # failed   # done   : running'
        return 0
    fi

    local cf="" cc="" cr="" reset="${_KNIT_COLORS[reset]}"
    _knit_brand_color cf magenta
    _knit_brand_color cc purple_dark
    _knit_brand_color cr purple
    printf -v __knit_ret '  %s%s%s failed   %s%s%s done   %s%s%s running' \
        "${cf}" "${_KNIT_PROGRESS_FULL}" "${reset}" \
        "${cc}" "${_KNIT_PROGRESS_FULL}" "${reset}" \
        "${cr}" "${_KNIT_PROGRESS_RUN}" "${reset}"
}

# ------------------------------------------------------------------------------
# @fn _knit_progress_bar_counts()
#
# Build the counts/percent text for one bar and return it by nameref. Reads
# "<c> done  <r> run  [<f> fail]  <rem> left  (<total>)  <pct>%" where the fail
# field is omitted when there are no failures and the percent is terminal progress
# floor(100 * (completed + failed) / total). With --label the text is prefixed by
# a fixed-width label column (used by the two-bar form). No color is used here.
#
# @param[out] __knit_ret Name of the variable to receive the counts string.
# @param[in] completed Number of completed items.
# @param[in] running Number of running items.
# @param[in] failed Number of failed/killed items.
# @param[in] remaining Number of not-yet-started items.
# @param[in] --label <text> Optional: prefix with a fixed-width label column.
# ------------------------------------------------------------------------------
_knit_progress_bar_counts() {
    local -n __knit_ret=$1
    shift
    local completed=$1 running=$2 failed=$3 remaining=$4
    shift 4
    local label=""
    [[ "${1:-}" == "--label" ]] && { label="$2"; shift 2; }

    local total=$(( completed + running + failed + remaining ))
    local pct=0
    (( total > 0 )) && pct=$(( 100 * (completed + failed) / total ))

    # Named with the __ prefix so it cannot shadow a caller outvar called "counts".
    local __knit_line="${completed} done  ${running} run"
    (( failed > 0 )) && __knit_line+="  ${failed} fail"
    __knit_line+="  ${remaining} left  (${total})  ${pct}%"

    if [[ -n "${label}" ]]; then
        printf -v __knit_ret '  %-10s %s' "${label}" "${__knit_line}"
    else
        printf -v __knit_ret '%s' "${__knit_line}"
    fi
}

# ------------------------------------------------------------------------------
# Progress bar — TTY draw layer
#
# knit_progress_bar / knit_progress_bar2 draw a framed bar live to stderr; they are
# a no-op unless stderr is a TTY and KNIT_LOG_LEVEL is at or below "info" (a quiet
# run gets no bar). On each call the terminal width is re-measured and the whole
# block (titled frame + interior bar row(s) + legend/counts) is rebuilt and
# repainted with a reflow-aware redraw, so a terminal resize — grow or shrink —
# repaints cleanly rather than stacking. knit_progress_bar_finish resets the redraw
# state and drops to a fresh line so a following knit_info prints below the frame.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @var _KNIT_PROGRESS_TL
# Top-left frame corner glyph (U+250C) for the progress bar.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROGRESS_TL
_KNIT_PROGRESS_TL=$'┌'

# ------------------------------------------------------------------------------
# @var _KNIT_PROGRESS_TR
# Top-right frame corner glyph (U+2510) for the progress bar.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROGRESS_TR
_KNIT_PROGRESS_TR=$'┐'

# ------------------------------------------------------------------------------
# @var _KNIT_PROGRESS_BL
# Bottom-left frame corner glyph (U+2514) for the progress bar.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROGRESS_BL
_KNIT_PROGRESS_BL=$'└'

# ------------------------------------------------------------------------------
# @var _KNIT_PROGRESS_BR
# Bottom-right frame corner glyph (U+2518) for the progress bar.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROGRESS_BR
_KNIT_PROGRESS_BR=$'┘'

# ------------------------------------------------------------------------------
# @var _KNIT_PROGRESS_H
# Horizontal frame rule glyph (U+2500) for the progress bar.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROGRESS_H
_KNIT_PROGRESS_H=$'─'

# ------------------------------------------------------------------------------
# @var _KNIT_PROGRESS_V
# Vertical frame side glyph (U+2502) for the progress bar.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROGRESS_V
_KNIT_PROGRESS_V=$'│'

# ------------------------------------------------------------------------------
# @var _KNIT_PROGRESS_LINES
#
# Number of logical lines the last progress block printed (0 before the first
# paint). Drives the cursor-up on the next redraw.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROGRESS_LINES
_KNIT_PROGRESS_LINES=0

# ------------------------------------------------------------------------------
# @var _KNIT_PROGRESS_WIDTH
#
# Terminal width the last progress block was printed at, used to compute how many
# physical rows it occupies now if the terminal has since been resized.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROGRESS_WIDTH
_KNIT_PROGRESS_WIDTH=0

# ------------------------------------------------------------------------------
# @fn _knit_progress_gate()
#
# Return success when a live progress bar should be drawn: stderr is a TTY and
# KNIT_LOG_LEVEL is at or below "info" (a warning-or-higher, i.e. quieter, run
# suppresses the bar). Failure otherwise.
# ------------------------------------------------------------------------------
_knit_progress_gate() {
    [[ -t 2 ]] || return 1
    local cur info
    _knit_log_level_to_int cur "${KNIT_LOG_LEVEL}"
    _knit_log_level_to_int info "info"
    (( cur <= info ))
}

# ------------------------------------------------------------------------------
# @fn _knit_progress_colored()
#
# Return success when the bar should be colorized: stderr is a TTY and NO_COLOR is
# unset. (The brand/16-color choice is then made by _knit_brand_color.)
# ------------------------------------------------------------------------------
_knit_progress_colored() {
    [[ -z "${NO_COLOR:-}" ]] && [[ -t 2 ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_progress_hbar()
#
# Print a run of <n> horizontal rule glyphs (no newline).
#
# @param[in] n Number of rule cells.
# ------------------------------------------------------------------------------
_knit_progress_hbar() {
    local n=$1 s="" i
    for (( i = 0; i < n; i++ )); do s+="${_KNIT_PROGRESS_H}"; done
    printf '%s' "${s}"
}

# ------------------------------------------------------------------------------
# @fn _knit_progress_rule_top()
#
# Print the frame's top rule for an interior width of <inner> cells, with an
# optional <title> embedded in the rule. The interior between the corners is one
# leading rule cell, the padded title, then the remaining rule cells, summing to
# exactly <inner>. Dimmed when color is enabled.
#
# @param[in] inner Interior width in cells.
# @param[in] title Optional title text.
# ------------------------------------------------------------------------------
_knit_progress_rule_top() {
    local inner=$1 title="${2:-}"
    local dim="" reset=""
    if _knit_progress_colored; then
        dim="${_KNIT_COLORS[dim]}"
        reset="${_KNIT_COLORS[reset]}"
    fi
    if [[ -n "${title}" ]]; then
        local label=" ${title} "
        local fill=$(( inner - 1 - ${#label} ))
        (( fill < 0 )) && fill=0
        printf '%s%s%s%s%s%s\n' "${dim}" "${_KNIT_PROGRESS_TL}${_KNIT_PROGRESS_H}" \
            "${label}" "$(_knit_progress_hbar "${fill}")" "${_KNIT_PROGRESS_TR}" "${reset}"
    else
        printf '%s%s%s%s%s\n' "${dim}" "${_KNIT_PROGRESS_TL}" \
            "$(_knit_progress_hbar "${inner}")" "${_KNIT_PROGRESS_TR}" "${reset}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_progress_rule_bottom()
#
# Print the frame's bottom rule for an interior width of <inner> cells. Dimmed when
# color is enabled.
#
# @param[in] inner Interior width in cells.
# ------------------------------------------------------------------------------
_knit_progress_rule_bottom() {
    local inner=$1
    local dim="" reset=""
    if _knit_progress_colored; then
        dim="${_KNIT_COLORS[dim]}"
        reset="${_KNIT_COLORS[reset]}"
    fi
    printf '%s%s%s%s%s\n' "${dim}" "${_KNIT_PROGRESS_BL}" \
        "$(_knit_progress_hbar "${inner}")" "${_KNIT_PROGRESS_BR}" "${reset}"
}

# ------------------------------------------------------------------------------
# @fn _knit_progress_side()
#
# Print one vertical frame side glyph. Dimmed when color is enabled.
# ------------------------------------------------------------------------------
_knit_progress_side() {
    local dim="" reset=""
    if _knit_progress_colored; then
        dim="${_KNIT_COLORS[dim]}"
        reset="${_KNIT_COLORS[reset]}"
    fi
    printf '%s%s%s' "${dim}" "${_KNIT_PROGRESS_V}" "${reset}"
}

# ------------------------------------------------------------------------------
# @fn _knit_progress_inner_width()
#
# Set the nameref given as the first argument to the interior width for the bar:
# the current terminal width (via _knit_terminal_width) minus the two frame sides,
# re-measured each call so the frame tracks the terminal. Falls back to a 40-cell
# interior when the width is unknown, and never goes below 10.
#
# @param[out] __knit_ret Name of the variable to receive the interior width.
# ------------------------------------------------------------------------------
_knit_progress_inner_width() {
    local -n __knit_ret=$1
    local tw=0
    _knit_terminal_width tw
    (( tw <= 0 )) && tw=42
    local iw=$(( tw - 2 ))
    (( iw < 10 )) && iw=10
    __knit_ret=${iw}
}

# ------------------------------------------------------------------------------
# @fn _knit_progress_clip()
#
# Clip a line to <max> display columns and return it by nameref, counting visible
# characters only — ANSI SGR escapes are copied through but do not count toward the
# width. Keeps a long line from wrapping onto a second physical row, which would
# desync the cursor-up redraw. A reset is appended if any color was still open at
# the cut.
#
# @param[out] __knit_ret Name of the variable to receive the clipped line.
# @param[in] line The line to clip (may contain ANSI escapes).
# @param[in] max Maximum display columns.
# ------------------------------------------------------------------------------
_knit_progress_clip() {
    local -n __knit_ret=$1
    local line=$2 max=$3
    local __knit_res="" vis=0 k=0 n=${#2}
    local saw_color=false
    while (( k < n )); do
        local ch="${line:k:1}"
        if [[ "${ch}" == $'\033' ]]; then
            local esc="${line:k}"
            if [[ "${esc}" =~ ^$'\033'\[[0-9\;]*[A-Za-z] ]]; then
                local tok="${BASH_REMATCH[0]}"
                __knit_res+="${tok}"
                k=$(( k + ${#tok} ))
                saw_color=true
                continue
            fi
        fi
        (( vis >= max )) && break
        __knit_res+="${ch}"
        vis=$(( vis + 1 ))
        k=$(( k + 1 ))
    done
    [[ "${saw_color}" == true ]] && __knit_res+="${_KNIT_COLORS[reset]}"
    __knit_ret="${__knit_res}"
}

# ------------------------------------------------------------------------------
# @fn _knit_progress_draw()
#
# Erase the previously drawn progress block and repaint <block> to stderr. Every
# line is clipped to the current terminal width so none wraps (printed-line count
# equals physical-row count). The cursor is moved up by the previous block's
# physical-row count — computed as its logical lines times ceil(prev_width /
# cur_width), to account for the terminal reflowing already-printed rows when it is
# made narrower — then everything below is erased (\033[J) before the new block is
# printed. Re-measuring and clipping each draw means a resize (grow or shrink)
# repaints at the new size without stacking or tearing.
#
# @param[in] block The multi-line block to paint (each line without a clear-to-eol).
# ------------------------------------------------------------------------------
_knit_progress_draw() {
    local block=$1
    local tw=0
    _knit_terminal_width tw
    (( tw <= 0 )) && tw=80

    # Clip each line to the current width (dropping any embedded clear-to-eol first)
    # and re-append a clear-to-eol, so leftover from a longer previous frame is wiped.
    local clipped="" line
    while IFS= read -r line; do
        line="${line//$'\033'\[K/}"
        local cl=""
        _knit_progress_clip cl "${line}" "${tw}"
        clipped+="${cl}"$'\033'"[K"$'\n'
    done <<< "${block%$'\n'}"
    block="${clipped}"

    local lines=${block//[!$'\n']/}
    lines=${#lines}

    if (( _KNIT_PROGRESS_LINES > 0 )); then
        local oldw=${_KNIT_PROGRESS_WIDTH}
        (( oldw < 1 )) && oldw=${tw}
        local rowspan=$(( (oldw + tw - 1) / tw ))
        (( rowspan < 1 )) && rowspan=1
        printf '\r\033[%dA\033[J' "$(( _KNIT_PROGRESS_LINES * rowspan ))" >&2
    fi
    printf '%s' "${block}" >&2
    _KNIT_PROGRESS_LINES=${lines}
    _KNIT_PROGRESS_WIDTH=${tw}
}

# ------------------------------------------------------------------------------
# @fn knit_progress_bar()
#
# Draw one full-width framed progress bar live to stderr, in place. A no-op unless
# stderr is a TTY and KNIT_LOG_LEVEL <= info (see _knit_progress_gate). Call once
# per observable state change; call knit_progress_bar_finish once at the end.
#
# @param[in] title Title shown in the frame's top rule.
# @param[in] completed Number of completed items.
# @param[in] running Number of running items.
# @param[in] failed Number of failed/killed items.
# @param[in] remaining Number of not-yet-started items.
# ------------------------------------------------------------------------------
knit_progress_bar() {
    _knit_progress_gate || return 0
    local title=$1 completed=$2 running=$3 failed=$4 remaining=$5

    local nocolor=()
    _knit_progress_colored || nocolor=(--no-color)

    local inner
    _knit_progress_inner_width inner

    local fill="" legend="" counts=""
    _knit_progress_bar_render fill "${inner}" "${completed}" "${running}" \
        "${failed}" "${remaining}" "${nocolor[@]}"
    _knit_progress_bar_legend legend "${nocolor[@]}"
    _knit_progress_bar_counts counts "${completed}" "${running}" "${failed}" \
        "${remaining}"

    local block=""
    block+="$(_knit_progress_rule_top "${inner}" "${title}")"$'\n'
    block+="$(printf '%s%s%s' "$(_knit_progress_side)" "${fill}" "$(_knit_progress_side)")"$'\n'
    block+="$(_knit_progress_rule_bottom "${inner}")"$'\n'
    block+="$(printf '%s      %s' "${legend}" "${counts}")"$'\n'

    _knit_progress_draw "${block}"
}

# ------------------------------------------------------------------------------
# @fn knit_progress_bar2()
#
# Draw two stacked framed progress bars sharing one frame, live to stderr, in
# place. Each bar is a labelled interior row; the legend and two labelled count
# lines sit below the frame. A no-op under the same gate as knit_progress_bar. Used
# for the two-budget case (e.g. a "current" bar and a "campaign" bar).
#
# @param[in] title Title shown in the frame's top rule.
# @param[in] c1 r1 f1 rem1 Counts for the first bar.
# @param[in] label1 Label for the first bar.
# @param[in] c2 r2 f2 rem2 Counts for the second bar.
# @param[in] label2 Label for the second bar.
# ------------------------------------------------------------------------------
knit_progress_bar2() {
    _knit_progress_gate || return 0
    local title=$1
    shift
    local c1=$1 r1=$2 f1=$3 rem1=$4 label1=$5
    shift 5
    local c2=$1 r2=$2 f2=$3 rem2=$4 label2=$5
    shift 5

    local nocolor=()
    _knit_progress_colored || nocolor=(--no-color)

    local inner
    _knit_progress_inner_width inner
    # Reserve a label column inside the frame; the bar fills the rest.
    local labw=11
    local barw=$(( inner - labw ))
    (( barw < 10 )) && barw=10

    local fill1="" fill2="" legend="" cnt1="" cnt2=""
    _knit_progress_bar_render fill1 "${barw}" "${c1}" "${r1}" "${f1}" "${rem1}" "${nocolor[@]}"
    _knit_progress_bar_render fill2 "${barw}" "${c2}" "${r2}" "${f2}" "${rem2}" "${nocolor[@]}"
    _knit_progress_bar_legend legend "${nocolor[@]}"
    _knit_progress_bar_counts cnt1 "${c1}" "${r1}" "${f1}" "${rem1}" --label "${label1}"
    _knit_progress_bar_counts cnt2 "${c2}" "${r2}" "${f2}" "${rem2}" --label "${label2}"

    local block=""
    block+="$(_knit_progress_rule_top "${inner}" "${title}")"$'\n'
    block+="$(printf '%s %-*s%s%s' "$(_knit_progress_side)" "$(( labw - 1 ))" \
        "${label1}" "${fill1}" "$(_knit_progress_side)")"$'\n'
    block+="$(printf '%s %-*s%s%s' "$(_knit_progress_side)" "$(( labw - 1 ))" \
        "${label2}" "${fill2}" "$(_knit_progress_side)")"$'\n'
    block+="$(_knit_progress_rule_bottom "${inner}")"$'\n'
    block+="${legend}"$'\n'
    block+="${cnt1}"$'\n'
    block+="${cnt2}"$'\n'

    _knit_progress_draw "${block}"
}

# ------------------------------------------------------------------------------
# @fn knit_progress_bar_finish()
#
# Finish a progress-bar sequence: reset the redraw state and emit a trailing
# newline so a following knit_info prints on a fresh line below the final frame. A
# no-op under the same gate as knit_progress_bar.
# ------------------------------------------------------------------------------
knit_progress_bar_finish() {
    _knit_progress_gate || return 0
    _KNIT_PROGRESS_LINES=0
    _KNIT_PROGRESS_WIDTH=0
    printf '\n' >&2
}
