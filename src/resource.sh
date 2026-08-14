#!/bin/bash

## @file resource.sh

# ------------------------------------------------------------------------------
# @fn _knit_resource_root()
#
# Store the resolved resource root — the directory under which resource instances
# live — in the caller-named variable. Reads the verbatim __resource_path__ from
# the metadata table (falling back to "resources" when unset, for robustness) and
# resolves it against the experiment root via _knit_resolve_experiment_path.
# Mirrors _knit_setup_root / _knit_job_root.
#
# @param __knit_ret Name of the variable to hold the resolved resource root.
# ------------------------------------------------------------------------------
_knit_resource_root() {
    local -n __knit_ret=$1
    local stored
    _knit_metadata_get stored "__resource_path__"
    [[ -z "${stored}" ]] && stored="resources"
    local resolved
    _knit_resolve_experiment_path resolved "${stored}"
    __knit_ret="${resolved}"
}

# ------------------------------------------------------------------------------
# @fn knit_resource_path()
#
# Resolve a resource instance name into its absolute directory under the
# experiment's resource root: `<resource-root>/<name>` (see _knit_resource_root),
# and print it to stdout. This is how the body of a command that depends on a
# resource turns a resource parameter value (the instance name) into an on-disk
# path:
#
# ```
# train_dir="$(knit_resource_path "$(knit_get_parameter training_dataset "$@")")"
# ```
#
# The name is validated as a single path component first (fatal otherwise). Fatals
# when the named instance does not exist, since a body should never run against a
# resource that was never fetched. Called at most a handful of times per body (one
# per declared resource), so it returns via stdout rather than a nameref.
#
# @param name The resource instance name (as passed to `knit fetch --name`).
# ------------------------------------------------------------------------------
knit_resource_path() {
    local name="$1"
    _knit_validate_instance_name "${name}"
    local root
    _knit_resource_root root
    local path="${root}/${name}"
    if [[ ! -d "${path}" ]]; then
        knit_fatal "Resource \"${name}\" not found at \"${path}\". Fetch it first with: ./${KNIT_SCRIPT_NAME} fetch --name ${name} -- <resource-type> [args...]"
    fi
    printf '%s\n' "${path}"
}
