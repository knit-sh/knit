#!/bin/bash

# ------------------------------------------------------------------------------
# @fn knit_pushd()
#
# Silent version of pushd.
# ------------------------------------------------------------------------------
knit_pushd() {
    knit_trace "Entering $(realpath "$1")"
    command pushd "$@" > /dev/null || return 1
}

# ------------------------------------------------------------------------------
# @fn knit_popd()
#
# Silent version of popd.
# ------------------------------------------------------------------------------
knit_popd() {
    knit_trace "Leaving $(pwd)"
    command popd "$@" > /dev/null || return 1
}
