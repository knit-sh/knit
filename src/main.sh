#!/bin/bash

## @file main.sh

# ------------------------------------------------------------------------------
# Version of the Knit framework. This committed value is a development
# placeholder: released artifacts are stamped with the exact git tag at build
# time (see the knit.sh target in the Makefile), so this file never needs
# editing when cutting a release.
# ------------------------------------------------------------------------------
declare -gxr KNIT_VERSION=0.0.0-dev

knit_register "__main__" knit_empty \
    "/!\\ Please use knit_set_program_description to provide a description here /!\\"
_knit_is_builtin
knit_hidden
knit_done

# ------------------------------------------------------------------------------
# @fn knit()
#
# This is the main function that invokes the Knit framework. Users should call
# it as follows at the end of their bash script to forward all arguments to it.
#
# ```
# knit $@
# ```
# ------------------------------------------------------------------------------
knit() {
    if [[ "$1" == "--help" ]]; then
        _knit_invoke_command "__main__" "--help"
    else
        _knit_invoke_command "$@"
    fi
}

# ------------------------------------------------------------------------------
# @var _KNIT_JUMP_TO_DIR
#
# Opt-in, internal environment variable used by the re-entry paths (submit,
# run) to relocate the shell after the framework has been sourced. Those paths
# arrange for the experiment to be sourced from the directory holding knit.sh
# (so a bare `source knit.sh` resolves) and set this variable to the directory
# the body should actually run in. When it is unset (the normal top-level
# invocation) nothing happens: the feature is fully inert for ordinary runs.
# ------------------------------------------------------------------------------
if [[ -n "${_KNIT_JUMP_TO_DIR:-}" ]]; then
    # Unset first so a stale exported value cannot make an unrelated child that
    # sources knit.sh cd unexpectedly; each re-entry sets it fresh.
    _knit_jump_to_dir="${_KNIT_JUMP_TO_DIR}"
    unset _KNIT_JUMP_TO_DIR
    cd "${_knit_jump_to_dir}" \
        || knit_fatal "cannot cd to ${_knit_jump_to_dir}"
    unset _knit_jump_to_dir
fi
