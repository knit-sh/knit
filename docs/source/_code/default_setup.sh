#!/bin/bash

# doc-check: source-only
#
# Showcase for the "Provide the default setup" recipe: the builtin "default"
# setup and the setup-adoption rules. Bootstrap auto-instantiates a "default"
# setup that carries only the platform activation, so a job that declares no
# setup still runs inside one and inherits the platform environment. A job may
# opt out with knit_without_setup, or any command may require the default
# explicitly with knit_with_setup "default".
#
# Source-only: submitting jobs and materializing setups needs a scheduler and a
# provisioned environment, neither of which runs in plain CI, so check-docs only
# syntax-checks this file.

source knit.sh

# Shared body: report the platform marker carried by the default setup's
# activation (unset when no setup, and thus no platform activation, is in effect).
_report_marker() {
    echo "marker: ${KNIT_MODULE_MARKER:-<unset>}"
}

# START adopt
# A job that declares NEITHER knit_with_setup NOR knit_without_setup adopts the
# builtin "default" setup automatically, inheriting the platform environment.
knit_register_job "adopt" _report_marker "Runs in the builtin default setup."
knit_done
# END adopt

# START optout
# knit_without_setup makes a job run with no setup at all: no setup directory and
# no platform activation. It is mutually exclusive with knit_with_setup.
knit_register_job "optout" _report_marker "Runs with no setup."
knit_without_setup
knit_done
# END optout

# START require-default
# Any command (not just jobs) can require the default setup explicitly, exactly
# like a named setup type.
knit_register "report" _report_marker "Requires the builtin default setup."
knit_with_setup "default"
knit_done
# END require-default

knit "$@"
