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
# @fn _knit_artifacts_row_sql()
#
# Build (print, without executing) the INSERT for one artifacts row: one produced
# artifact, with its uuid "id" (the target of the "produced" edge), its
# artifacts-relative "path" (UNIQUE), the declared "name", the "type" ("file" or
# "directory"), the content "checksum", and the "result" flag. The text columns
# are single-quoted and escaped; "result" is emitted as a bare 0/1 integer (any
# value other than "1" becomes 0). Meant to be composed with a "produced" edge
# (see _knit_produced_edge_sql) into one transaction at record time, mirroring how
# _knit_prov_edge_sql composes into _knit_db_record_invocation.
#
# @param[in] id       UUID of the artifact row.
# @param[in] path     Artifacts-relative path (UNIQUE).
# @param[in] name     Declared artifact name.
# @param[in] type     "file" or "directory".
# @param[in] checksum Content digest of the resolved target ("sha256:<hex>").
# @param[in] result   "1" for a declared result, else 0.
# ------------------------------------------------------------------------------
_knit_artifacts_row_sql() {
    local id="$1"
    local path="$2"
    local name="$3"
    local type="$4"
    local checksum="$5"
    local result="$6"

    local tbl esc_id esc_path esc_name esc_type esc_checksum
    _knit_db_sql_ident tbl "${_KNIT_ARTIFACTS_TABLE}"
    _knit_sql_escape esc_id "${id}"
    _knit_sql_escape esc_path "${path}"
    _knit_sql_escape esc_name "${name}"
    _knit_sql_escape esc_type "${type}"
    _knit_sql_escape esc_checksum "${checksum}"
    local result_lit=0
    [[ "${result}" == "1" ]] && result_lit=1

    printf 'INSERT INTO %s (id, path, name, type, checksum, result) VALUES (%s, %s, %s, %s, %s, %s);' \
        "${tbl}" \
        "'${esc_id}'" \
        "'${esc_path}'" \
        "'${esc_name}'" \
        "'${esc_type}'" \
        "'${esc_checksum}'" \
        "${result_lit}"
}

# ------------------------------------------------------------------------------
# @fn _knit_artifacts_record_sql()
#
# Build (into the caller's variable, without executing) the SQL that records every
# artifact the given command bound during this invocation: one artifacts row plus
# one "producer --produced--> artifact" edge per stashed binding. The result is
# spliced into the producing row's own transaction (see _knit_db_record_invocation)
# so the row, its "call" edge, and its produced artifacts are written atomically.
#
# Each binding was stashed by knit_artifact keyed on the artifacts-relative path;
# the name and content digest come from that stash, while the type ("file" or
# "directory") and the "result" flag are recovered from registration state (the
# fileparam marker and the results set). A fresh uuid identifies each artifacts
# row (the target of its "produced" edge). The caller's variable is left empty
# when the command bound no artifact.
#
# @param[out] __knit_ret     Name of the variable to hold the built SQL.
# @param[in]  cmd            Mangled command name of the producer.
# @param[in]  producer_id    Row id of the producing invocation (the edge source).
# @param[in]  producer_name  Demangled producer name (the edge source_name).
# ------------------------------------------------------------------------------
_knit_artifacts_record_sql() {
    local -n __knit_ret=$1
    local cmd="$2"
    local producer_id="$3"
    local producer_name="$4"
    __knit_ret=""
    _knit_set_exists "_KNIT_CMD_${cmd}_artifact_name" || return 0
    # shellcheck disable=SC2178 # nameref to the command's binding stash
    local -n _knit_ar_names="_KNIT_CMD_${cmd}_artifact_name"
    # shellcheck disable=SC2178 # nameref to the command's binding stash
    local -n _knit_ar_sums="_KNIT_CMD_${cmd}_artifact_checksum"
    # Test the results set only when it exists: _knit_set_find on a missing set
    # would arithmetic-evaluate a subscript that names an in-scope variable,
    # recursing.
    local has_results=""
    _knit_set_exists "_KNIT_CMD_${cmd}_results" && has_results=1
    local rel normalized kind marker marker_var result aid row_sql edge_sql
    local parts=""
    for rel in "${!_knit_ar_names[@]}"; do
        normalized="${_knit_ar_names[${rel}]}"
        # Recover the declared kind ("file"/"directory") from the fileparam marker
        # ("output:<kind>:yes") and the result flag from the results set.
        marker_var="_KNIT_CMD_${cmd}_fileparam_${normalized}"
        marker="${!marker_var:-}"
        kind="${marker#output:}"
        kind="${kind%%:*}"
        result=0
        [[ -n "${has_results}" ]] \
            && _knit_set_find "_KNIT_CMD_${cmd}_results" "${normalized}" && result=1
        aid="$(_knit_uuidv7)"
        row_sql="$(_knit_artifacts_row_sql \
            "${aid}" "${rel}" "${normalized}" "${kind}" "${_knit_ar_sums[${rel}]}" "${result}")"
        edge_sql="$(_knit_produced_edge_sql \
            "${producer_id}" "${producer_name}" "${aid}")"
        parts+="${row_sql}"$'\n'"${edge_sql}"$'\n'
    done
    __knit_ret="${parts}"
}

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
# Add an artifact of the command being registered to its artifacts set: a name
# that refers to a file or directory that lives under the artifacts root and is
# bound at runtime with knit_artifact. Membership in this set is what marks a name
# as an artifact rather than an ordinary value output; it drives how the command
# is described and, later, how knit_artifact validates the name. An artifact is
# not an output column, so it is kept out of the outputs set.
#
# The per-command _KNIT_CMD_<cmd>_artifacts set is created as associative on
# first use (knit_register does not create it, since not every command has an
# artifact).
#
# Only meaningful in a command context; a call with no command being registered
# is a no-op.
#
# @param[in] name The declared (un-normalized) artifact name.
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
# @fn knit_with_output_artifact()
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
# knit_with_output_artifact "table:file" "The results table (CSV)."
# tabulate() {
#    out="$(knit_artifact_dir)"
#    compute > "${out}/table.csv"
#    knit_artifact "table" "table.csv"
# }
# ```
#
# Unlike an ordinary output, an artifact is NOT a column of the command's own
# table. Each binding is recorded at runtime as one row in the framework-owned
# artifacts table (its artifacts-relative path, name, type, content checksum, and
# result flag) with a "produced" edge from the producing invocation, so a file
# can be traced back to what made it. The content digest is always recorded for
# an artifact, so there is no --no-checksum opt-out here. The artifact is added to
# the command's artifacts set, and its type/description are kept in registration
# state so knit describe can report it.
#
# Because a "produced" edge needs the producing invocation's row as its source, a
# command that declares an artifact records an invocation row even if it declared
# no table of its own: a table is ensured automatically at knit_done time.
#
# @param[in] param Artifact name followed by ":type" ("file" or "directory").
# @param[in] description Description of the artifact.
# @param[in] --result Optional flag; mark the artifact as a result (what the
#        experiment was for).
# ------------------------------------------------------------------------------
knit_with_output_artifact() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_output_artifact should be used after a call to \"knit_register\"."
    fi
    _knit_wrapper_reject_declaration "knit_with_output_artifact"
    knit_check_arguments "" "result" "${@:3}" \
        || knit_fatal "knit_with_output_artifact takes an artifact, a description, and an optional --result."
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
    # Reserve the name against the command's whole name space: a duplicate
    # artifact, or a clash with a parameter, an output, or a synthesized checksum
    # column, is rejected uniformly. An artifact is not itself an output column,
    # but it shares the name space (it is referred to by name at runtime).
    _knit_reserve_name "_KNIT_CMD_${cmd}" "${demangled_cmd}" "Artifact" "${param_name}" "${output}"
    knit_trace "Adding artifact \"${param_name}\" (type: ${param_type}) to command \"${demangled_cmd}\"."
    printf -v "_KNIT_CMD_${cmd}_3_${output}_description" '%s' "$2"
    printf -v "_KNIT_CMD_${cmd}_3_${output}_default"     '%s' ""
    printf -v "_KNIT_CMD_${cmd}_3_${output}_type"        '%s' "${param_type}"
    # An artifact is recorded as a row in the artifacts table (with a "produced"
    # edge), not as a column of the command's own table. It is kept in the
    # command's artifacts set (not the outputs set), so it synthesizes no
    # "<name>" or "<name>-checksum" column and knit describe reports it as a
    # produced entity. Register only the existence/type marker the runtime reads to
    # validate and hash the bound entry.
    _knit_register_fileparam "output" "${param_type}" "${param_name}" "yes"
    _knit_register_artifact "${param_name}"
    if _knit_decl_flag_present "result" "${@:3}"; then
        _knit_register_result "${param_name}"
    fi
    # A "produced" edge needs the producing invocation's row as its source, so
    # make sure the command records one even if it declared no table of its own.
    _knit_artifact_require_table
}

# ------------------------------------------------------------------------------
# @fn _knit_artifact_require_table()
#
# Guarantee that the command currently being registered will record an invocation
# row, so a "produced" edge from it has a source. Called by knit_with_output_artifact.
# The row comes from the command's table; if the command declares its own table
# (knit_with_table) nothing more is needed, so this only pushes a knit_done
# callback (_knit_artifact_ensure_table_cb) that creates a default table when none
# was declared. The callback is pushed at most once per command, however many
# artifacts it declares.
# ------------------------------------------------------------------------------
_knit_artifact_require_table() {
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local guard="_KNIT_CMD_${cmd}_artifact_table_cb"
    [[ -n "${!guard:-}" ]] && return 0
    printf -v "${guard}" '%s' "1"
    _knit_push_done_cb _knit_artifact_ensure_table_cb "${cmd}"
}

# ------------------------------------------------------------------------------
# @fn _knit_artifact_ensure_table_cb()
#
# knit_done callback (installed by _knit_artifact_require_table) that gives an
# artifact-producing command a table when it declared none, so its invocation is
# recorded and can be the source of a "produced" edge. A command that declared
# its own table with knit_with_table is left untouched. The auto-created table
# takes the command's own (demangled) name, mirroring knit_with_table's default,
# is registered in the names map, and is set up immediately (deferred to first use
# when the experiment is not yet bootstrapped, exactly like knit_with_table).
#
# @param[in] cmd Mangled command name.
# ------------------------------------------------------------------------------
_knit_artifact_ensure_table_cb() {
    local cmd="$1"
    local table_var="_KNIT_CMD_${cmd}_table"
    # The command declared its own table: its row already anchors the edge.
    [[ -n "${!table_var:-}" ]] && return 0
    local demangled
    demangled=$(_knit_command_demangle "${cmd}")
    # The default table name (the command name) should be free, since the command
    # declared no table; guard anyway to fail loudly rather than clash silently.
    if [[ -v _KNIT_DB_REGISTERED_TABLES["${demangled}"] ]]; then
        knit_fatal "Cannot auto-create a table for artifact-producing command \"${demangled}\": table \"${demangled}\" is already used by \"${_KNIT_DB_REGISTERED_TABLES[${demangled}]}\"."
    fi
    _KNIT_DB_REGISTERED_TABLES["${demangled}"]="${demangled}"
    printf -v "${table_var}" '%s' "${demangled}"
    _knit_db_setup_table "${cmd}" "${demangled}"
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
    demangled_cmd=$(_knit_command_display "${cmd}")
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
    # The binding stash keys on that path (its presence is the write-once guard)
    # and holds the declared name and, below, the content digest; at record time
    # each entry becomes one artifacts row plus a "produced" edge.
    _knit_set_exists "_KNIT_CMD_${cmd}_artifact_name" \
        || declare -gA "_KNIT_CMD_${cmd}_artifact_name=()"
    _knit_set_exists "_KNIT_CMD_${cmd}_artifact_checksum" \
        || declare -gA "_KNIT_CMD_${cmd}_artifact_checksum=()"
    # shellcheck disable=SC2178 # nameref to the command's binding stash
    local -n names_ref="_KNIT_CMD_${cmd}_artifact_name"
    if [[ -v names_ref["${rel}"] ]]; then
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
    # Checksum the resolved target (recursive for a directory).
    local hex
    _knit_sha256 hex "${abs}"
    # Stash the binding for record time: the recording path emits one artifacts
    # row (path, name, type, checksum, result) and one "produced" edge per entry.
    knit_trace "Binding artifact \"${name}\" = \"${rel}\" for command \"${demangled_cmd}\"."
    # shellcheck disable=SC2178 # nameref to the command's binding stash
    local -n sums_ref="_KNIT_CMD_${cmd}_artifact_checksum"
    # shellcheck disable=SC2034 # written through the nameref
    names_ref["${rel}"]="${normalized}"
    # shellcheck disable=SC2034 # written through the nameref
    sums_ref["${rel}"]="sha256:${hex}"
}
