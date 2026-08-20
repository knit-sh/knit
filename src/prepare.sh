#!/bin/bash

## @file prepare.sh
##
## The `prepare` dispatcher: build and record a job without dispatching it to the
## scheduler. A prepared job gets a "jobs" row with state "prepared" and stays
## queued until released by `submit prepared` / `submit next`. `prepare` mirrors
## `submit` argument-for-argument (minus --wait) over the same _KNIT_JOBS
## registry, so you prepare the same jobs you submit: `prepare -- <job>` builds
## the job through _knit_prepare_build exactly as `submit` does, but stops before
## the dispatch phase.
##
## `prepare` declares neither a table nor outputs of its own: _knit_prepare_build
## records the "jobs" row under the "submit" command identity (see job.sh), so a
## prepared job and a directly-submitted job produce identically-shaped,
## identically-labeled rows and provenance edges. The prepare dispatcher is
## therefore transparent to the graph (knit_without_provenance).

knit_register "prepare" _knit_prepare "Prepare a job without submitting it."
_knit_is_builtin
# The job's "jobs" row is recorded under the "submit" identity, so the prepare
# dispatcher itself contributes no provenance node of its own.
knit_without_provenance
_knit_declare_submit_options

# ------------------------------------------------------------------------------
# @fn _knit_prepare()
#
# Entry point for the `prepare` CLI command. Builds a submission and records it
# with state "prepared" without contacting the scheduler (see
# _knit_prepare_build): the batch script and the frozen .submit metadata are
# written, but no scheduler command is issued and no .job.id is recorded. The job
# stays queued until released by `submit prepared` or `submit next`. Prints the
# job UUID (the canonical, scheduler-independent identifier).
#
# Usage:
# ```
# ./exp.sh prepare [--setup <setup-name>] [--name <alias>] [--group <name>] \
#     [sched-args...] -- job-name [args...]
# ```
# ------------------------------------------------------------------------------
_knit_prepare() {
    # The output variable names must not clash with _knit_prepare_build's own
    # internal locals (uuid/jobdir/alias_link/job_name), or the nameref outputs
    # would be shadowed (see the nameref-shadow-collision convention).
    # shellcheck disable=SC2034 # out_jobdir/out_alias/out_jobname are nameref
    # outputs of _knit_prepare_build; prepare only needs the uuid it returns.
    local out_uuid out_jobdir out_alias out_jobname
    _knit_prepare_build out_uuid out_jobdir out_alias out_jobname \
        "prepared" "$@"
    printf '%s\n' "${out_uuid}"
}
knit_done
