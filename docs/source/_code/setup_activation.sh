#!/bin/bash
#
# Showcase for declarative setup activation. A setup declares its environment
# with knit_setup_env_set / _prepend / _append / _unset and
# knit_setup_activate_line instead of relying on an environment snapshot. Knit
# records each declaration as a composable line in the setup's .activate.sh, so a
# dependent job's activation EXTENDS the job's own environment (its PATH entry is
# prepended, not overwritten) rather than replacing it.
#
# This example runs in plain CI: the setup only declares environment (no build,
# no network), and the "probe" job runs on the portable local backend.

source knit.sh

knit_set_program_description "Declarative setup activation demo."

# START setup
@setup "toolenv" "Declare a composable software environment."
_toolenv_setup() {
    # Each call changes THIS build shell now and records one composable line in
    # <setup>/.activate.sh for every dependent command to replay.

    # Set a plain variable.
    knit_setup_env_set TOOL_GREETING "hello"

    # Prepend to PATH. The recorded line keeps ${PATH} literal, so a dependent
    # job adds this entry to its OWN PATH instead of overwriting it.
    knit_setup_env_prepend PATH "${KNIT_SETUP_PREFIX}/bin"

    # Append to a search path. Empty-safe: no leading separator on an empty var.
    knit_setup_env_append TOOL_DATA_PATH "${KNIT_SETUP_PREFIX}/share"

    # Remove a variable from every dependent command's environment.
    knit_setup_env_unset TOOL_LEGACY

    # Record a verbatim line. It runs in declaration order, so it can build on a
    # variable set above.
    knit_setup_activate_line 'export TOOL_BANNER="${TOOL_GREETING}-from-setup"'
}
@done
# END setup

# START job
@job "probe" "Run inside the setup and report the composed environment."
@with_setup "toolenv"
@with_output "greeting:string"  "" "TOOL_GREETING declared by the setup."
@with_output "banner:string"    "" "TOOL_BANNER built by the activate line."
@with_output "data_path:string" "" "TOOL_DATA_PATH appended by the setup."
@with_output "legacy:string"    "" "TOOL_LEGACY (unset by the setup; empty here)."
@with_output "path:string"      "" "The job's PATH after activation."
probe() {
    # The setup's environment is already composed onto this job's own shell: its
    # variables are set and its PATH entry is prepended to the job's own PATH.
    knit_output "greeting"   "${TOOL_GREETING:-<unset>}"
    knit_output "banner"     "${TOOL_BANNER:-<unset>}"
    knit_output "data_path"  "${TOOL_DATA_PATH:-<unset>}"
    knit_output "legacy"     "${TOOL_LEGACY:-<unset>}"
    knit_output "path"       "${PATH}"
}
@done
# END job

knit "$@"
