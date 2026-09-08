#!/bin/bash

## @file bundle.sh

# ------------------------------------------------------------------------------
# @var _KNIT_BUNDLE_REQUIRES
#
# Extra files the experiment needs but Knit does not otherwise track (a config
# file, a small input, a post-processing script). Each entry is a path string
# recorded verbatim by knit_bundle_requires, in declaration order. The paths are
# meant to be relative to the experiment script's directory; validation and glob
# expansion happen later, when "knit bundle" runs, not at declaration time.
# ------------------------------------------------------------------------------
declare -ga _KNIT_BUNDLE_REQUIRES
_KNIT_BUNDLE_REQUIRES=()

# ------------------------------------------------------------------------------
# @fn knit_bundle_requires()
#
# Declare an extra file, directory, or glob that "knit bundle" must add to the
# archive. Called at the top of an experiment script (like
# knit_set_program_description), not inside a knit_register/knit_done block. It
# describes the experiment as a whole, so it appends to the global
# _KNIT_BUNDLE_REQUIRES array rather than to any one command.
#
# The path is stored verbatim. This function MUST NOT touch the filesystem — no
# stat, no existence check, no knit_fatal. The experiment script is re-sourced on
# every invocation, including on a compute node that re-enters a job, so a
# declaration that failed on a missing or non-relocatable path would abort that
# re-entry and kill the job. All validation (path exists, path is relative, path
# stays inside the tree) and glob expansion are deferred to "knit bundle".
#
# @param[in] path A file, directory, or glob pattern, relative to the experiment
#                 script's directory.
# ------------------------------------------------------------------------------
knit_bundle_requires() {
    _KNIT_BUNDLE_REQUIRES+=("$1")
}
