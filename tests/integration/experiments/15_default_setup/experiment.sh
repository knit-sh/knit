#!/usr/bin/env bash
# Integration test experiment 15_default_setup.
#
# Exercises the builtin "default" setup and the setup-adoption rules. Bootstrap
# auto-instantiates a "default" setup that carries only the platform activation
# (here: the profile's Lmod modules), so a job that declares no setup still runs
# inside one and inherits the platform environment. The knit-marker module sets
# KNIT_MODULE_MARKER, which stands in for "the platform environment is visible".
#
# Registers four commands sharing one body that just reports the marker:
#   - job "adopt":    declares NEITHER knit_with_setup NOR knit_without_setup, so
#                     it adopts the builtin default setup implicitly and sees the
#                     marker.
#   - job "optout":   declares knit_without_setup, so it runs with no setup and
#                     does NOT see the marker.
#   - command "plaincmd": a plain (non-job) command with no setup declaration.
#                     Only jobs adopt the default setup implicitly, so it runs
#                     with no setup and sees nothing.
#   - command "withdefault": a plain command that requires the default setup
#                     explicitly with knit_with_setup "default"; it resolves to
#                     the auto-instantiated default setup and sees the marker.

source /shared/knit/knit.sh

knit_set_program_description \
    "Builtin default setup and setup-adoption rules integration test."

# Shared body: report the platform marker carried by the default setup's
# activation. KNIT_MODULE_MARKER is set by the profile's knit-marker module; it
# is <unset> when no setup (and thus no platform activation) is in effect.
__report_marker() {
    printf 'marker: %s\n' "${KNIT_MODULE_MARKER:-<unset>}"
}

# A job that declares neither directive adopts the builtin default setup.
knit_register_job "adopt" __report_marker \
    "Job that declares no setup and therefore adopts the builtin default setup."
knit_done

# The same body, opting out: no setup at all, so the marker stays unset.
knit_register_job "optout" __report_marker \
    "Job that opts out of any setup with knit_without_setup."
knit_without_setup
knit_done

# A plain command does not adopt the default setup implicitly (only jobs do).
knit_register __report_marker "plaincmd" \
    "Plain command with no setup declaration (no implicit adoption)."
knit_done

# A plain command may require the default setup explicitly.
knit_register __report_marker "withdefault" \
    "Plain command that requires the builtin default setup explicitly."
knit_with_setup "default"
knit_done

knit "$@"
