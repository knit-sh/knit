#!/bin/bash

## @file artifact.sh

# ------------------------------------------------------------------------------
# @fn _knit_artifact_root()
#
# Store the resolved artifact root — the directory under which artifacts live —
# in the caller-named variable. Reads the verbatim __artifact_path__ from the
# metadata table (falling back to "artifacts" when unset, for robustness) and
# resolves it against the experiment root via _knit_resolve_experiment_path.
# Mirrors _knit_setup_root / _knit_job_root / _knit_resource_root.
#
# @param[out] __knit_ret Name of the variable to hold the resolved artifact root.
# ------------------------------------------------------------------------------
_knit_artifact_root() {
    local -n __knit_ret=$1
    local stored
    _knit_metadata_get stored "__artifact_path__"
    [[ -z "${stored}" ]] && stored="artifacts"
    local resolved
    _knit_resolve_experiment_path resolved "${stored}"
    __knit_ret="${resolved}"
}

# ------------------------------------------------------------------------------
# @fn knit_artifact_dir()
#
# Print the resolved artifact root (see _knit_artifact_root) to stdout. This is
# the "write into artifacts/ then declare" helper: a command body puts a file (or
# a symlink to it) under this directory, then binds it with knit_artifact:
#
# ```
# out="$(knit_artifact_dir)"
# compute > "${out}/table.csv"
# knit_artifact "table" "table.csv"
# ```
#
# The directory is not created here; creation is lazy, on first bind. Called at
# most a handful of times per body, so it returns via stdout rather than a
# nameref.
# ------------------------------------------------------------------------------
knit_artifact_dir() {
    local root
    _knit_artifact_root root
    printf '%s\n' "${root}"
}
