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
