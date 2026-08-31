#!/bin/bash

# doc-check: source-only
#
# Showcase for the "Provide the default setup" recipe: the builtin "default"
# setup and the setup-adoption rules. Bootstrap auto-instantiates a "default"
# setup that carries only the platform activation, so a job that declares no
# setup still runs inside one and inherits the platform environment. A job may
# opt out with @without_setup, or any command may require the default
# explicitly with @with_setup "default".
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
# A job that declares NEITHER @with_setup NOR @without_setup adopts the
# builtin "default" setup automatically, inheriting the platform environment.
@job "adopt" "Runs in the builtin default setup."
adopt() { _report_marker; }
@done
# END adopt

# START optout
# @without_setup makes a job run with no setup at all: no setup directory and
# no platform activation. It is mutually exclusive with @with_setup.
@job "optout" "Runs with no setup."
@without_setup
optout() { _report_marker; }
@done
# END optout

# START require-default
# Any command (not just jobs) can require the default setup explicitly, exactly
# like a named setup type.
@command "report" "Requires the builtin default setup."
@with_setup "default"
report() { _report_marker; }
@done
# END require-default

knit "$@"
