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

# ------------------------------------------------------------------------------
# @fn _knit_register_artifact()
#
# Add an output of the command being registered to its artifacts set: an output
# that names a file or directory that lives under the artifacts root and is bound
# at runtime with knit_artifact. Membership in this set is what distinguishes an
# artifact output from an ordinary value output; it carries no behavior beyond
# how the command is described and, later, how knit_artifact validates the name.
#
# The per-command _KNIT_CMD_<cmd>_artifacts set is created as associative on
# first use (knit_register does not create it, since not every command has an
# artifact).
#
# Only meaningful in a command context; a call with no command being registered
# is a no-op. The output must already have been added to the outputs set before
# this is called.
#
# @param[in] name The declared (un-normalized) artifact/output name.
# ------------------------------------------------------------------------------
_knit_register_artifact() {
    local name="$1"
    [[ -v _KNIT_CURRENT_COMMAND ]] || return 0
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local output
    output=$(_knit_name_normalize "${name}")
    _knit_set_exists "_KNIT_CMD_${cmd}_artifacts" \
        || _knit_set_new "_KNIT_CMD_${cmd}_artifacts"
    _knit_set_add "_KNIT_CMD_${cmd}_artifacts" "${output}"
}

# ------------------------------------------------------------------------------
# @fn knit_with_artifact()
#
# This function should be called right after a call to knit_register (or one of
# its variants) to declare an artifact that the command produces: a file or
# directory, kept under the artifacts root, that the command binds at runtime
# with knit_artifact. It is the file/directory counterpart of knit_with_output.
# The artifact name must include a type annotation using the "name:type" syntax,
# and the type must be "file" or "directory" (the "dir" alias is accepted).
#
# Example:
# ```
# knit_register "tabulate" "tabulate" "Tabulate results."
# knit_with_artifact "table:file" "The results table (CSV)."
# tabulate() {
#    out="$(knit_artifact_dir)"
#    compute > "${out}/table.csv"
#    knit_artifact "table" "table.csv"
# }
# ```
#
# Like an ordinary output, an artifact becomes a recorded column of the command's
# table, together with an automatic "<name>-checksum" companion column (the
# content digest is always recorded for artifacts, so there is no --no-checksum
# opt-out here). The artifact is additionally added to the command's artifacts
# set. It has no default value; its recorded value is the artifacts-relative path
# set by knit_artifact at runtime.
#
# @param[in] param Artifact name followed by ":type" ("file" or "directory").
# @param[in] description Description of the artifact.
# @param[in] --result Optional flag; mark the artifact as a result (what the
#        experiment was for).
# ------------------------------------------------------------------------------
knit_with_artifact() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_artifact should be used after a call to \"knit_register\"."
    fi
    _knit_wrapper_reject_declaration "knit_with_artifact"
    knit_check_arguments "" "result" "${@:3}" \
        || knit_fatal "knit_with_artifact takes an artifact, a description, and an optional --result."
    local param_spec="$1"
    if [[ "${param_spec}" != *:* ]]; then
        knit_fatal "Artifact \"${param_spec}\" is missing a type annotation (expected \"name:type\")."
    fi
    local param_name="${param_spec%%:*}"
    local param_type="${param_spec#*:}"
    if ! _knit_name_is_valid "${param_name}"; then
        knit_fatal "Artifact \"${param_name}\" does not have a valid name."
    fi
    if ! knit_type_exists "${param_type}"; then
        knit_fatal "Artifact \"${param_name}\" has unknown type \"${param_type}\"."
    fi
    if ! _knit_type_is_checksummable "${param_type}"; then
        knit_fatal "Artifact \"${param_name}\" must be of type \"file\" or \"directory\", not \"${param_type}\"."
    fi
    if [ -z "$2" ]; then
        knit_warning "Not describing artifact \"${param_name}\" undermines its understandability."
    fi
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local demangled_cmd="${_KNIT_CURRENT_COMMAND_DEMANGLED}"
    local output
    output=$(_knit_name_normalize "${param_name}")
    if _knit_set_find "_KNIT_CMD_${cmd}_outputs" "${output}"; then
        knit_fatal "Artifact \"${param_name}\" already declared for \"${demangled_cmd}\"."
    fi
    # An artifact and a parameter map to the same table column, so their
    # normalized names must not collide.
    if _knit_set_find "_KNIT_CMD_${cmd}_required" "${output}" \
    || _knit_set_find "_KNIT_CMD_${cmd}_optional" "${output}" \
    || _knit_set_find "_KNIT_CMD_${cmd}_flags"    "${output}"; then
        knit_fatal "Artifact \"${param_name}\" collides with a declared parameter of \"${demangled_cmd}\"."
    fi
    knit_trace "Adding artifact \"${param_name}\" (type: ${param_type}) to command \"${demangled_cmd}\"."
    printf -v "_KNIT_CMD_${cmd}_3_${output}_description" '%s' "$2"
    printf -v "_KNIT_CMD_${cmd}_3_${output}_default"     '%s' ""
    printf -v "_KNIT_CMD_${cmd}_3_${output}_type"        '%s' "${param_type}"
    _knit_set_add "_KNIT_CMD_${cmd}_outputs" "${output}"
    # Artifacts are always checksummed (no --no-checksum opt-out); this also adds
    # the companion "<name>-checksum" column via the shared output machinery.
    _knit_register_checksum "output" "${param_type}" "${param_name}" "false"
    _knit_register_artifact "${param_name}"
    if _knit_decl_flag_present "result" "${@:3}"; then
        _knit_register_result "${param_name}"
    fi
}
