#!/bin/bash

## @file str.sh

# ------------------------------------------------------------------------------
# @fn _knit_str_hyphens_to_underscores()
#
# Convert hyphens to underscores, storing the result in the caller-named
# variable.
#
# @param __knit_ret Name of the variable to hold the result.
# @param input String to convert.
# ------------------------------------------------------------------------------
_knit_str_hyphens_to_underscores() {
  local -n __knit_ret=$1
  __knit_ret="${2//-/_}"
}

# ------------------------------------------------------------------------------
# @fn _knit_str_underscores_to_hyphens()
#
# Convert underscores to hyphens, storing the result in the caller-named
# variable.
#
# @param __knit_ret Name of the variable to hold the result.
# @param input String to convert.
# ------------------------------------------------------------------------------
_knit_str_underscores_to_hyphens() {
  local -n __knit_ret=$1
  __knit_ret="${2//_/-}"
}

# ------------------------------------------------------------------------------
# @fn _knit_str_render_cmd()
#
# Render an argument vector, passed by array name, as a single shell-safe string:
# each element is %q-quoted and the elements are joined by single spaces. An empty
# array renders to the empty string. Used to capture the resolved launcher and
# scheduler commands for the "native_cmd" columns of the runs and jobs tables and
# for the trace log emitted before each command is issued.
#
# @param argv_name Name of the array holding the command and its arguments.
# ------------------------------------------------------------------------------
_knit_str_render_cmd() {
  # shellcheck disable=SC2178 # nameref to the caller's array
  local -n _cmd_argv="$1"
  local out=""
  (( ${#_cmd_argv[@]} )) && printf -v out '%q ' "${_cmd_argv[@]}"
  printf '%s' "${out% }"
}
