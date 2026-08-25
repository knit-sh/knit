#!/bin/bash

## @file sched_none.sh

# ------------------------------------------------------------------------------
# The "none" backend is for a user who owns a multi-node cluster but does not
# submit through a batch scheduler (SSH-reachable nodes, a hand-maintained MPI
# hostfile, etc.). A job launches exactly as the local backend does — as a
# background process on the submitting host — so the lifecycle functions
# (directives, submit, cancel, wait) delegate to their local counterparts. The
# only difference is host reporting: the allocation is the node list configured
# at bootstrap via --default-nodefile (metadata __default_nodefile__), not just
# the submitting host's name. That is what _knit_sched_none_hostfile provides.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_sched_none_directives()
#
# Emit the batch directives for the none backend. Like the local backend, the
# job runs as a background process with no scheduler, so there are no directives.
# Delegates to _knit_sched_local_directives.
#
# @param[in] arr_name Name of the resolved-options associative array.
# @param[in] jobdir   Job directory.
# ------------------------------------------------------------------------------
_knit_sched_none_directives() {
    _knit_sched_local_directives "$@"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_none_submit()
#
# Submit a batch script for the none backend by running it as a detached
# background process on the submitting host, identically to the local backend.
# Delegates to _knit_sched_local_submit, which handles stdout/stderr redirection,
# walltime, and optional blocking, and prints the process id.
#
# @param[in] arr_name Name of the resolved-options associative array.
# @param[in] script   Path to the batch script to run.
# @param[in] jobdir   Job directory holding .stdout/.stderr.
# ------------------------------------------------------------------------------
_knit_sched_none_submit() {
    _knit_sched_local_submit "$@"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_none_submit_cmdline()
#
# Build the none backend's submission command, identically to the local backend
# (the job runs as a background "bash <script>" on this host). Delegates to
# _knit_sched_local_submit_cmdline.
#
# @param[in] argv_name Name of the array to fill with the submission argv.
# @param[in] arr_name  Name of the resolved-options associative array.
# @param[in] script    Path to the batch script to run.
# ------------------------------------------------------------------------------
_knit_sched_none_submit_cmdline() {
    _knit_sched_local_submit_cmdline "$@"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_none_wait()
#
# Block until a none-backend job process exits. Identical to the local backend
# (the job is a background process on this host). Delegates to
# _knit_sched_local_wait.
#
# @param[in] pid Process id recorded in the job's .job.id.
# ------------------------------------------------------------------------------
_knit_sched_none_wait() {
    _knit_sched_local_wait "$@"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_none_cancel()
#
# Cancel a none-backend job by signalling its process, identically to the local
# backend. Delegates to _knit_sched_local_cancel.
#
# @param[in] pid Process id recorded in the job's .job.id.
# ------------------------------------------------------------------------------
_knit_sched_none_cancel() {
    _knit_sched_local_cancel "$@"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_none_hostfile()
#
# Print the host list for a none-backend job: the contents of the node file
# configured at bootstrap (metadata __default_nodefile__), one host per line.
# This is the "raw" host list per the dispatcher contract — entries may repeat
# or carry a trailing ":N" slot count; callers such as knit_job_hostnames
# deduplicate and clean it. Blank lines are dropped so an empty entry never
# reaches the normaliser. When no readable node file is configured (unset, or
# the path does not exist / is not readable), warn and fall back to this
# machine's hostname.
# ------------------------------------------------------------------------------
_knit_sched_none_hostfile() {
    local nodefile
    _knit_metadata_get nodefile "__default_nodefile__"
    if [[ -n "${nodefile}" && -r "${nodefile}" ]]; then
        grep -v '^[[:space:]]*$' "${nodefile}"
    else
        knit_warning "The 'none' scheduler has no readable default nodefile; reporting the local hostname only."
        hostname
    fi
}
