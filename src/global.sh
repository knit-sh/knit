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
