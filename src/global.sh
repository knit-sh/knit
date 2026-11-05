#!/bin/bash

## @file global.sh

# ------------------------------------------------------------------------------
# @var KNIT_SCRIPT_NAME
#
# Base name (without directories) of the experiment script that sourced
# knit.sh. Useful for constructing user-facing messages.
# ------------------------------------------------------------------------------
declare -g KNIT_SCRIPT_NAME
# shellcheck disable=SC2034 # used in error messages across other source files
KNIT_SCRIPT_NAME="$(basename "$0")"

# ------------------------------------------------------------------------------
# @var _KNIT_SCRIPT_ARGV
#
# The positional parameters the experiment script was invoked with, captured at
# the very top of the concatenated knit.sh (which is sourced with no arguments
# of its own, so "$@" here is the experiment's own argv). Plugin import and
# bootstrap materialization consult this to tell the current command apart (for
# example "bootstrap", which must also materialize into .knit/, from an ordinary
# run) without re-parsing the command line.
# ------------------------------------------------------------------------------
declare -ga _KNIT_SCRIPT_ARGV
# shellcheck disable=SC2034 # consumed by plugin import and bootstrap materialization
_KNIT_SCRIPT_ARGV=("$@")

# ------------------------------------------------------------------------------
# @var _KNIT_ON_FATAL
#
# List of callback command strings run by knit_fatal just before it exits. Each
# entry is a single command, pre-escaped with printf %q (as knit_run_before /
# knit_run_after store their callbacks), so it can be re-run with eval. A
# callback registers via knit_on_fatal.
#
# The list is empty in almost every context (the login side, bootstrap, any
# ordinary command), so knit_fatal's drain is a no-op there. It exists so a
# compute-side job can record a terminal "failed" state when its body or a
# before-callback aborts with knit_fatal, which exits the process before the
# normal after-callback (that would record the state) can run.
# ------------------------------------------------------------------------------
declare -ga _KNIT_ON_FATAL
_KNIT_ON_FATAL=()

# ------------------------------------------------------------------------------
# @var _KNIT_SCRIPT_PATH
#
# Absolute, resolved path to the experiment script that sourced knit.sh. Unlike
# KNIT_SCRIPT_NAME (a base name for messages), this is a runnable path, captured
# at load time before any directory change, so commands that re-execute the
# experiment (for example "submit drain" releasing jobs in a loop) can invoke it
# reliably regardless of the current working directory.
# ------------------------------------------------------------------------------
declare -g _KNIT_SCRIPT_PATH
# shellcheck disable=SC2034 # used by commands that re-execute the experiment
_KNIT_SCRIPT_PATH="$(realpath -- "$0" 2>/dev/null || printf '%s' "$0")"

# ------------------------------------------------------------------------------
# @fn _knit_stdout_is_terminal()
#
# Return success when standard output is a terminal. Factored into its own
# function so callers that colorize or wrap output based on the terminal (e.g.
# "--help" highlighting and describe) can stub it in tests to force the terminal
# path on or off deterministically.
# ------------------------------------------------------------------------------
_knit_stdout_is_terminal() {
    [[ -t 1 ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_terminal_width()
#
# Set the nameref given as the first argument to the width of the terminal (in
# columns), or to "0" when the width cannot be used for wrapping — i.e. when
# standard output is not a terminal or "stty size" yields no usable value.
# Callers treat a "0" result as "no wrapping". Factored into its own function
# (mirroring _knit_stdout_is_terminal) so tests can stub it to force a width
# deterministically.
#
# The result is returned by nameref rather than printed for capture with command
# substitution: the terminal check (_knit_stdout_is_terminal, i.e. "[[ -t 1 ]]")
# must be evaluated in the caller's context, where file descriptor 1 is the real
# help destination. A command substitution would replace fd 1 with a pipe and so
# always report "not a terminal", disabling wrapping even on a real terminal.
#
# @param[out] __knit_ret Name of the variable to receive the width (or "0").
# ------------------------------------------------------------------------------
_knit_terminal_width() {
    local -n __knit_ret=$1
    if ! _knit_stdout_is_terminal; then
        __knit_ret=0
        return 0
    fi
    # Named to avoid a nameref shadow collision if a caller passes a variable
    # called "width" as the output argument.
    local __knit_width
    # Redirect stderr before stdin so that a failure to open /dev/tty (possible
    # when there is no controlling terminal) is suppressed rather than leaking.
    # "read" returns non-zero on empty input (e.g. when /dev/tty cannot be
    # opened); that is handled by the guard below, so do not let it propagate.
    IFS=' ' read -r _ __knit_width \
        < <(stty size 2>/dev/null </dev/tty || printf '') || true
    if [[ -z "${__knit_width:-}" || ! "${__knit_width}" =~ ^[0-9]+$ ]]; then
        __knit_ret=0
        return 0
    fi
    __knit_ret="${__knit_width}"
}

# ------------------------------------------------------------------------------
# @var KNIT_SCRIPT_PATH
#
# Absolute path of the experiment script that sourced knit.sh. Used when
# generating batch scripts so the compute node can re-enter the experiment
# (`exp.sh submit <job-name> ...`) regardless of its current directory.
# ------------------------------------------------------------------------------
declare -g KNIT_SCRIPT_PATH
# shellcheck disable=SC2034 # used when generating job scripts in sched.sh
KNIT_SCRIPT_PATH="$(realpath "$0" 2>/dev/null || printf '%s' "$0")"

# ------------------------------------------------------------------------------
# @var _KNIT_IS_BOOTSTRAPPING
#
# Set to "true" when the first argument passed to the experiment script is
# "bootstrap", i.e. when the user is running the bootstrap command.
# Functions that require a bootstrapped experiment use this to distinguish
# between a legitimate pre-bootstrap invocation (during bootstrap itself) and
# an erroneous one (calling a DB-backed command before bootstrap has run).
# ------------------------------------------------------------------------------
declare -g _KNIT_IS_BOOTSTRAPPING
_KNIT_IS_BOOTSTRAPPING="false"
if [[ "${1:-}" == "bootstrap" ]]; then
    _KNIT_IS_BOOTSTRAPPING="true"
fi

# ------------------------------------------------------------------------------
# @var _KNIT_COLORS
#
# Associative array mapping color and style names to their ANSI escape
# sequences. Use these to colorize terminal output. The "reset" entry clears
# all active attributes.
#
# Foreground colors: black, red, green, yellow, blue, magenta, cyan, white,
#                    bright_black, bright_red, bright_green, bright_yellow,
#                    bright_blue, bright_magenta, bright_cyan, bright_white.
# Background colors: bg_black, bg_red, bg_green, bg_yellow, bg_blue,
#                    bg_magenta, bg_cyan, bg_white, bg_bright_black,
#                    bg_bright_red, bg_bright_green, bg_bright_yellow,
#                    bg_bright_blue, bg_bright_magenta, bg_bright_cyan,
#                    bg_bright_white.
# Styles:            bold, dim, italic, underline, blink, reverse, hidden,
#                    strikethrough.
# ------------------------------------------------------------------------------
declare -gA _KNIT_COLORS
_KNIT_COLORS=(
    # Reset
    [reset]=$'\033[0m'
    # Styles
    [bold]=$'\033[1m'
    [dim]=$'\033[2m'
    [italic]=$'\033[3m'
    [underline]=$'\033[4m'
    [blink]=$'\033[5m'
    [reverse]=$'\033[7m'
    [hidden]=$'\033[8m'
    [strikethrough]=$'\033[9m'
    # Foreground colors
    [black]=$'\033[30m'
    [red]=$'\033[31m'
    [green]=$'\033[32m'
    [yellow]=$'\033[33m'
    [blue]=$'\033[34m'
    [magenta]=$'\033[35m'
    [cyan]=$'\033[36m'
    [white]=$'\033[37m'
    # Bright foreground colors
    [bright_black]=$'\033[90m'
    [bright_red]=$'\033[91m'
    [bright_green]=$'\033[92m'
    [bright_yellow]=$'\033[93m'
    [bright_blue]=$'\033[94m'
    [bright_magenta]=$'\033[95m'
    [bright_cyan]=$'\033[96m'
    [bright_white]=$'\033[97m'
    # Background colors
    [bg_black]=$'\033[40m'
    [bg_red]=$'\033[41m'
    [bg_green]=$'\033[42m'
    [bg_yellow]=$'\033[43m'
    [bg_blue]=$'\033[44m'
    [bg_magenta]=$'\033[45m'
    [bg_cyan]=$'\033[46m'
    [bg_white]=$'\033[47m'
    # Bright background colors
    [bg_bright_black]=$'\033[100m'
    [bg_bright_red]=$'\033[101m'
    [bg_bright_green]=$'\033[102m'
    [bg_bright_yellow]=$'\033[103m'
    [bg_bright_blue]=$'\033[104m'
    [bg_bright_magenta]=$'\033[105m'
    [bg_bright_cyan]=$'\033[106m'
    [bg_bright_white]=$'\033[107m'
)

# ------------------------------------------------------------------------------
# @var _KNIT_BRAND_TRUECOLOR
#
# Knit brand accent colors as 24-bit truecolor escape sequences, taken from the
# landing-page palette (docs/pygments-knit/knit_pygments.py, mirroring
# web/styles.css). Used where knit wants its own identity rather than one of the
# basic ANSI colors (e.g. the progress bar sections). Keys:
#   magenta      #b83a83  (--knit-magenta, red-magenta)
#   purple       #9e7fd4  (--knit-purple, light purple)
#   purple_dark  #5f4c7f  (dark purple; brand purple shifted darker, same hue)
# ------------------------------------------------------------------------------
declare -gA _KNIT_BRAND_TRUECOLOR
_KNIT_BRAND_TRUECOLOR=(
    [magenta]=$'\033[38;2;184;58;131m'
    [purple]=$'\033[38;2;158;127;212m'
    [purple_dark]=$'\033[38;2;95;76;127m'
)

# ------------------------------------------------------------------------------
# @var _KNIT_BRAND_FALLBACK
#
# Nearest basic 16-color ANSI escape for each brand color, used when the terminal
# does not support 24-bit truecolor. Chosen so colorized output stays legible and
# the brand colors remain distinguishable from one another.
# ------------------------------------------------------------------------------
declare -gA _KNIT_BRAND_FALLBACK
_KNIT_BRAND_FALLBACK=(
    [magenta]=$'\033[35m'
    [purple]=$'\033[95m'
    [purple_dark]=$'\033[34m'
)

# ------------------------------------------------------------------------------
# @fn _knit_truecolor()
#
# Return success (0) when the terminal supports 24-bit truecolor, failure (1)
# otherwise. COLORTERM (truecolor/24bit) is the explicit signal, but many
# terminals that support truecolor leave COLORTERM empty, so a modern TERM is
# also accepted. KNIT_FORCE_16COLOR forces failure and KNIT_TRUECOLOR forces
# success (both for testing the two code paths deterministically).
# ------------------------------------------------------------------------------
_knit_truecolor() {
    [[ -n "${KNIT_FORCE_16COLOR:-}" ]] && return 1
    [[ -n "${KNIT_TRUECOLOR:-}" ]] && return 0
    case "${COLORTERM:-}" in
        truecolor | 24bit) return 0 ;;
    esac
    case "${TERM:-}" in
        *-256color | *-direct | xterm* | screen* | tmux* | vte* | kitty* | \
            alacritty* | wezterm* | foot*)
            return 0
            ;;
    esac
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_brand_color()
#
# Set the nameref given as the first argument to the escape sequence for a brand
# color, resolved to truecolor when the terminal supports it (see
# _knit_truecolor) or the nearest 16-color ANSI otherwise. The brand key is one
# of: magenta, purple, purple_dark.
#
# @param[out] __knit_ret Name of the variable to receive the escape sequence.
# @param[in] key Brand color key (magenta | purple | purple_dark).
# ------------------------------------------------------------------------------
_knit_brand_color() {
    local -n __knit_ret=$1
    if _knit_truecolor; then
        __knit_ret="${_KNIT_BRAND_TRUECOLOR[$2]}"
    else
        __knit_ret="${_KNIT_BRAND_FALLBACK[$2]}"
    fi
}
