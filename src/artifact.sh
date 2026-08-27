#!/bin/bash

## @file artifact.sh

# ------------------------------------------------------------------------------
# @var _KNIT_ARTIFACTS_TABLE
#
# Name of the framework-owned table that records one row per produced artifact (a
# first-class provenance node, like "jobs" and "runs"). A "produced" edge in the
# __provenance__ table links a producing invocation to the artifact row whose id
# it names. A direct names-map entry (see below) resolves "artifacts" as a graph
# node label; the table has no owning command.
# ------------------------------------------------------------------------------
declare -g _KNIT_ARTIFACTS_TABLE
_KNIT_ARTIFACTS_TABLE="artifacts"

# ------------------------------------------------------------------------------
# @var _KNIT_ARTIFACTS_TABLE_ENSURED
#
# Set to "1" once the artifacts table has been ensured in this process (see
# _knit_artifacts_ensure_table), so the idempotent CREATE runs at most once per
# run. Mirrors _KNIT_PROV_TABLE_ENSURED.
# ------------------------------------------------------------------------------
declare -g _KNIT_ARTIFACTS_TABLE_ENSURED
_KNIT_ARTIFACTS_TABLE_ENSURED=""

# ------------------------------------------------------------------------------
# @fn _knit_artifacts_create_table()
#
# Create the artifacts table if it does not already exist. Each row is one
# produced artifact: a stable identity ("id", a uuidv7, the target of the
# "produced" edge), the artifacts-relative "path" (UNIQUE, since an on-disk entry
# is write-once), the declared "name" the producer used, the "type" ("file" or
# "directory"), the content "checksum" ("sha256:<hex>"), and a "result" flag
# (1 when declared --result, else 0). The schema is fixed here rather than
# derived from a command's declared outputs (unlike a per-command table), so its
# column order and the UNIQUE constraint on "path" are explicit. Called at
# bootstrap alongside the metadata and __provenance__ tables.
# ------------------------------------------------------------------------------
_knit_artifacts_create_table() {
    local artifacts_ident
    _knit_db_sql_ident artifacts_ident "${_KNIT_ARTIFACTS_TABLE}"
    _knit_sqlite3_write <<EOF
CREATE TABLE IF NOT EXISTS ${artifacts_ident} (
    id        TEXT,
    path      TEXT UNIQUE,
    name      TEXT,
    type      TEXT,
    checksum  TEXT,
    result    INTEGER
);
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_artifacts_ensure_table()
#
# Ensure the artifacts table exists before an artifact row is written, creating
# it lazily on first use. A freshly bootstrapped experiment already has the table
# (created at bootstrap); a database bootstrapped before this feature shipped does
# not, so ensuring it here lets a new invocation record artifacts rather than
# failing. The create is idempotent and runs at most once per process, guarded by
# _KNIT_ARTIFACTS_TABLE_ENSURED. Mirrors _knit_prov_ensure_table.
# ------------------------------------------------------------------------------
_knit_artifacts_ensure_table() {
    [[ -n "${_KNIT_ARTIFACTS_TABLE_ENSURED}" ]] && return 0
    _knit_artifacts_create_table
    _KNIT_ARTIFACTS_TABLE_ENSURED="1"
}

# ------------------------------------------------------------------------------
# Register the artifacts table as a graph node in the query names map. Unlike a
# per-command table (jobs, runs), it has no owning command: it is written by
# whichever invocation produces an artifact, and its schema is fixed here (see
# _knit_artifacts_create_table), not derived from declared outputs. A direct
# "artifacts=artifacts" entry is all knit_query_build_names needs to expose
# "artifacts" as a Cypher node label (the target_name of a "produced" edge); it
# also makes the name fatal to reuse (knit_with_table / knit_as both guard on a
# present key), exactly as an owning command would, without a phantom command or
# an unwanted knit_with_table schema callback.
# ------------------------------------------------------------------------------
_KNIT_DB_REGISTERED_TABLES["${_KNIT_ARTIFACTS_TABLE}"]="${_KNIT_ARTIFACTS_TABLE}"

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

# ------------------------------------------------------------------------------
# @fn _knit_artifact_resolve_path()
#
# Resolve a user-supplied <linked-path> into the artifact entry's absolute
# location and its artifacts-relative form, enforcing containment on the entry's
# OWN location, not its target. A relative <linked-path> is taken against the
# artifacts root; an absolute one is used as given. The parent directory is
# resolved to its real path (so a symlink in the parent chain is followed), while
# the final component is kept verbatim (a symlink there is not followed, so a
# symlink artifact stays inside the artifacts root even when its target is
# elsewhere). Containment holds when that real parent is the artifacts root or a
# directory below it.
#
# @param[out] __knit_ret1 Name of the variable to hold the absolute entry path.
# @param[out] __knit_ret2 Name of the variable to hold the artifacts-relative path.
# @param[in] root         The resolved (absolute) artifacts root.
# @param[in] linked_path  The user-supplied <linked-path>.
# @return 0 on success (contained); 1 when <linked-path> is outside the root.
# ------------------------------------------------------------------------------
_knit_artifact_resolve_path() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local root="$3"
    local linked_path="$4"
    # Interpret a relative <linked-path> against the artifacts root.
    local input="${linked_path}"
    [[ "${input}" == /* ]] || input="${root}/${input}"
    # Resolve the parent's real path but keep the final component, so a symlink
    # entry is not followed for the containment test.
    local parent base parent_real root_real
    parent=$(dirname "${input}")
    base=$(basename "${input}")
    parent_real=$(realpath -m "${parent}")
    root_real=$(realpath -m "${root}")
    if [[ "${parent_real}" != "${root_real}" \
       && "${parent_real}" != "${root_real}/"* ]]; then
        return 1
    fi
    __knit_ret1="${parent_real}/${base}"
    __knit_ret2="${__knit_ret1#"${root_real}/"}"
}

# ------------------------------------------------------------------------------
# @fn knit_artifact()
#
# Bind a declared artifact of the currently executing command to a path inside
# the artifacts root. It is the file/directory counterpart of knit_output: the
# body first puts the file (or a symlink to it) under the artifacts root, then
# declares it here.
#
# ```
# out="$(knit_artifact_dir)"
# compute > "${out}/table.csv"
# knit_artifact "table" "table.csv"
# ```
#
# <linked-path> is either relative to the artifacts root or absolute and inside
# it. The entry's own location (not its target) must sit inside the artifacts
# root; a symlink entry is allowed and its target may be anywhere. The entry must
# exist and match the declared type (a symlink is followed to its target for this
# check). The content digest of the resolved target is recorded automatically in
# the companion "<name>-checksum" column, and the recorded value of the artifact
# is always the artifacts-relative path, whatever form was passed, so the record
# holds no absolute machine path. Binding the same artifacts-relative path twice
# in one invocation is fatal: artifacts are write-once.
#
# The optional --link-from / --copy-from shortcuts create the entry from a source
# that lives elsewhere, so the body does not have to place it by hand. They are
# mutually exclusive. Both create the parent directories inside the artifacts
# root and refuse to overwrite an on-disk entry. --link-from resolves <real-path>
# to an absolute path and makes an absolute-target symlink at <linked-path> (the
# real bytes stay where they are, at zero copy cost); --copy-from does "cp -r"
# into <linked-path>. Either way <real-path> must exist, and the created entry
# then goes through the same existence, type, and checksum path as the
# direct-write form.
#
# ```
# knit_artifact "dataset" "dataset.h5" --link-from /fast/aaa/bigfile
# knit_artifact "figure"  "figure.svg" --copy-from "${out}/figure.svg"
# ```
#
# Fails if called outside an executing command, if <name> is not a declared
# artifact of that command, if <linked-path> is empty or outside the artifacts
# root, if the entry does not exist or has the wrong type, if the path was
# already bound in this invocation, if both shortcuts are given, if a shortcut's
# <real-path> is missing or does not exist, or if a shortcut would overwrite an
# on-disk entry.
#
# @param[in] name        Artifact name (hyphens and underscores are interchangeable).
# @param[in] linked_path Path inside the artifacts root where the entry lives.
# @param[in] --link-from Optional; symlink <linked-path> to this <real-path>.
# @param[in] --copy-from Optional; copy this <real-path> to <linked-path>.
# ------------------------------------------------------------------------------
knit_artifact() {
    local name="$1"
    local linked_path="$2"
    # Suppressed on non-root ranks of a run: discard the binding but warn, so the
    # user learns to guard knit_artifact with a rank-0 check (only rank 0 records).
    if [[ -n "${_KNIT_RECORDING_SUPPRESSED}" ]]; then
        knit_warning "Recording is suppressed on this rank; artifact \"${name}\" is discarded. Guard knit_artifact with a rank-0 check (e.g. [[ \"\${KNIT_MPI_RANK}\" == 0 ]])."
        return 0
    fi
    # Parse the optional --link-from / --copy-from shortcuts by hand: these are
    # direct user-facing arguments, not the CLI framework's "--flag true" form.
    local link_src="" copy_src="" have_link=0 have_copy=0
    local extra=( "${@:3}" )
    local i=0
    while [[ ${i} -lt ${#extra[@]} ]]; do
        case "${extra[${i}]}" in
            --link-from)
                have_link=1
                link_src="${extra[$((i + 1))]:-}"
                i=$((i + 2))
                ;;
            --copy-from)
                have_copy=1
                copy_src="${extra[$((i + 1))]:-}"
                i=$((i + 2))
                ;;
            *)
                knit_fatal "knit_artifact: unexpected argument \"${extra[${i}]}\"."
                ;;
        esac
    done
    if [[ ${have_link} -eq 1 && ${have_copy} -eq 1 ]]; then
        knit_fatal "knit_artifact: --link-from and --copy-from are mutually exclusive."
    fi
    local shortcut="" src=""
    if [[ ${have_link} -eq 1 ]]; then
        shortcut="link"
        src="${link_src}"
    elif [[ ${have_copy} -eq 1 ]]; then
        shortcut="copy"
        src="${copy_src}"
    fi
    if [[ -n "${shortcut}" && -z "${src}" ]]; then
        knit_fatal "knit_artifact: --${shortcut}-from requires a path argument."
    fi
    if [[ ${#_KNIT_EXECUTING_COMMAND[@]} -eq 0 ]]; then
        knit_fatal "knit_artifact should be called from within a registered command function."
    fi
    local cmd="${_KNIT_EXECUTING_COMMAND[-1]}"
    local demangled_cmd
    demangled_cmd=$(_knit_command_demangle "${cmd}")
    local normalized
    normalized=$(_knit_name_normalize "${name}")
    if ! _knit_set_find "_KNIT_CMD_${cmd}_artifacts" "${normalized}"; then
        knit_fatal "\"${name}\" is not a declared artifact of command \"${demangled_cmd}\"."
    fi
    if [[ -z "${linked_path}" ]]; then
        knit_fatal "knit_artifact requires a path inside the artifacts directory for \"${name}\"."
    fi
    local root
    _knit_artifact_root root
    local abs rel
    if ! _knit_artifact_resolve_path abs rel "${root}" "${linked_path}"; then
        knit_fatal "Artifact \"${name}\" path \"${linked_path}\" is outside the artifacts directory \"${root}\"."
    fi
    # Write-once: an artifacts-relative path may be bound only once per invocation.
    _knit_set_exists "_KNIT_CMD_${cmd}_artifact_bound" \
        || declare -gA "_KNIT_CMD_${cmd}_artifact_bound=()"
    # shellcheck disable=SC2178 # nameref to the command's bound-path set
    local -n bound_ref="_KNIT_CMD_${cmd}_artifact_bound"
    if [[ -v bound_ref["${rel}"] ]]; then
        knit_fatal "Artifact path \"${rel}\" is already recorded for \"${demangled_cmd}\"; artifacts are write-once."
    fi
    # Shortcut: materialize the entry from a source elsewhere, then fall through
    # to the same existence/type/checksum path as the direct-write form.
    if [[ -n "${shortcut}" ]]; then
        if [[ ! -e "${src}" ]]; then
            knit_fatal "knit_artifact: source \"${src}\" for artifact \"${name}\" does not exist."
        fi
        # Never overwrite an on-disk entry (artifacts are write-once); the -L test
        # also catches a dangling symlink, which -e alone would miss.
        if [[ -e "${abs}" || -L "${abs}" ]]; then
            knit_fatal "knit_artifact: artifact path \"${rel}\" already exists on disk for \"${demangled_cmd}\"; artifacts are write-once."
        fi
        local parent_dir
        parent_dir=$(dirname "${abs}")
        mkdir -p "${parent_dir}" \
            || knit_fatal "knit_artifact: could not create \"${parent_dir}\" for artifact \"${name}\"."
        if [[ "${shortcut}" == "link" ]]; then
            # An absolute target keeps the symlink valid regardless of the cwd.
            local src_abs
            src_abs=$(realpath -m "${src}")
            ln -s "${src_abs}" "${abs}" \
                || knit_fatal "knit_artifact: could not link \"${abs}\" to \"${src_abs}\" for artifact \"${name}\"."
        else
            cp -r "${src}" "${abs}" \
                || knit_fatal "knit_artifact: could not copy \"${src}\" to \"${abs}\" for artifact \"${name}\"."
        fi
    fi
    # Existence and declared-type match, following a symlink to its target. The
    # fileparam marker holds the alias-resolved kind as "output:<kind>:yes".
    local marker_var="_KNIT_CMD_${cmd}_fileparam_${normalized}"
    local marker="${!marker_var:-}"
    local kind="${marker#output:}"
    kind="${kind%%:*}"
    _knit_checksum_require_exists "${demangled_cmd}" output "${name}" "${kind}" "${abs}"
    # Checksum the resolved target (recursive for a directory) and stash the
    # digest in the companion checksum column, reusing the file-checksums path.
    local hex
    _knit_sha256 hex "${abs}"
    _knit_checksum_stash "${cmd}" "${normalized}" "${hex}"
    # Record the artifacts-relative path as the output value and mark it bound.
    knit_trace "Binding artifact \"${name}\" = \"${rel}\" for command \"${demangled_cmd}\"."
    # shellcheck disable=SC2178 # nameref to the command's output-value array
    local -n output_ref="_KNIT_CMD_${cmd}_output_value"
    # shellcheck disable=SC2034 # written through the nameref
    output_ref["${normalized}"]="${rel}"
    # shellcheck disable=SC2034 # written through the nameref
    bound_ref["${rel}"]=1
}
