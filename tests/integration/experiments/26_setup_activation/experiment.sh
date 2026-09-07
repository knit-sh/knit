#!/usr/bin/env bash
# Integration test experiment 26_setup_activation.
#
# A hand-crafted "toolenv" setup declares a composable environment with the
# declarative activation functions instead of snapshotting its build shell:
#   - knit_setup_env_set        sets a plain variable
#   - knit_setup_env_prepend    prepends an entry to PATH
#   - knit_setup_env_append     appends an entry to a search path
#   - knit_setup_activate_line  records a verbatim line, in declaration order
#   - knit_setup_env_unset      removes a variable a prior line had set
#
# A dependent job "probe" sources that setup on the compute node and records the
# composed environment into its table, so the test can prove the activation
# EXTENDS the job's own environment (its PATH keeps its system entries and gains
# the setup's) rather than replacing it. The job is single-node with no MPI, so it
# runs identically on every backend.

source knit.sh

knit_set_program_description \
    "Declarative setup activation integration test experiment."

# The setup: declare a composable environment. Each call changes THIS build shell
# now and records one composable line in <setup>/.activate.sh for every dependent
# command to replay.
knit_register_setup "toolenv" __toolenv_setup \
    "Declare a composable software environment."
__toolenv_setup() {
    # A plain variable.
    knit_setup_env_set TOOL_GREETING "hello"

    # Prepend to PATH. The recorded line keeps ${PATH} literal, so a dependent
    # job adds this entry to its OWN PATH instead of overwriting it.
    knit_setup_env_prepend PATH "${KNIT_SETUP_PREFIX}/bin"

    # Append to a search path (empty-safe: no leading separator on an empty var).
    knit_setup_env_append TOOL_DATA_PATH "${KNIT_SETUP_PREFIX}/share"

    # A verbatim line. It runs in declaration order, so it can build on a variable
    # set above.
    knit_setup_activate_line 'export TOOL_BANNER="${TOOL_GREETING}-from-setup"'

    # env_unset removes a variable. Set it first with a verbatim line, then unset
    # it, so the recorded "unset" provably removes a set variable at job time.
    knit_setup_activate_line 'export TOOL_LEGACY="stale-value"'
    knit_setup_env_unset TOOL_LEGACY
}
knit_done

# The dependent job: runs inside the setup on the compute node and records the
# composed environment so the test can inspect it.
knit_register_job "probe" __probe_job \
    "Report the environment composed by the setup."
knit_with_setup "toolenv"
knit_with_output "greeting:string"  "" "TOOL_GREETING declared by the setup."
knit_with_output "banner:string"    "" "TOOL_BANNER built by the activate line."
knit_with_output "data_path:string" "" "TOOL_DATA_PATH appended by the setup."
knit_with_output "legacy:string"    "" "TOOL_LEGACY (set then unset by the setup)."
knit_with_output "path:string"      "" "The job's PATH after activation."
__probe_job() {
    # The setup's environment is already composed onto this job's own shell: its
    # variables are set and its PATH entry is prepended to the job's own PATH.
    knit_output "greeting"  "${TOOL_GREETING:-<unset>}"
    knit_output "banner"    "${TOOL_BANNER:-<unset>}"
    knit_output "data_path" "${TOOL_DATA_PATH:-<unset>}"
    knit_output "legacy"    "${TOOL_LEGACY:-<unset>}"
    knit_output "path"      "${PATH}"
    # A stdout anchor the test can wait on to guard against output-flush lag.
    printf '=== end ===\n'
}
knit_done

knit "$@"
