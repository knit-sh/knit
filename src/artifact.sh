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
# is write-once), the declared "name" the producer used, the physical "type"
# ("file" or "directory"), the semantic "kind" the producer declared ("csvfile",
# "rundir", ...; "file"/"directory" for a bare builtin), the content "checksum"
# ("sha256:<hex>"), and a "result" flag (1 when declared --result, else 0). The
# schema is fixed here rather than derived from a command's declared outputs
# (unlike a per-command table), so its column order and the UNIQUE constraint on
# "path" are explicit. Called at bootstrap alongside the metadata and
# __provenance__ tables.
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
    kind      TEXT,
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
# artifacts-relative "path" (UNIQUE), the declared "name", the physical "type"
# ("file" or "directory"), the semantic "kind" ("csvfile"/"rundir"/...;
# "file"/"directory" for a bare builtin), the content "checksum", and the
# "result" flag. The text columns are single-quoted and escaped; "result" is
# emitted as a bare 0/1 integer (any value other than "1" becomes 0). Meant to be
# composed with a "produced" edge (see _knit_produced_edge_sql) into one
# transaction at record time, mirroring how _knit_prov_edge_sql composes into
# _knit_db_record_invocation.
#
# @param[in] id       UUID of the artifact row.
# @param[in] path     Artifacts-relative path (UNIQUE).
# @param[in] name     Declared artifact name.
# @param[in] type     Physical type: "file" or "directory".
# @param[in] kind     Semantic kind the producer declared.
# @param[in] checksum Content digest of the resolved target ("sha256:<hex>").
# @param[in] result   "1" for a declared result, else 0.
# ------------------------------------------------------------------------------
_knit_artifacts_row_sql() {
    local id="$1"
    local path="$2"
    local name="$3"
    local type="$4"
    local kind="$5"
    local checksum="$6"
    local result="$7"

    local tbl esc_id esc_path esc_name esc_type esc_kind esc_checksum
    _knit_db_sql_ident tbl "${_KNIT_ARTIFACTS_TABLE}"
    _knit_sql_escape esc_id "${id}"
    _knit_sql_escape esc_path "${path}"
    _knit_sql_escape esc_name "${name}"
    _knit_sql_escape esc_type "${type}"
    _knit_sql_escape esc_kind "${kind}"
    _knit_sql_escape esc_checksum "${checksum}"
    local result_lit=0
    [[ "${result}" == "1" ]] && result_lit=1

    printf 'INSERT INTO %s (id, path, name, type, kind, checksum, result) VALUES (%s, %s, %s, %s, %s, %s, %s);' \
        "${tbl}" \
        "'${esc_id}'" \
        "'${esc_path}'" \
        "'${esc_name}'" \
        "'${esc_type}'" \
        "'${esc_kind}'" \
        "'${esc_checksum}'" \
        "${result_lit}"
}

# ------------------------------------------------------------------------------
# @fn _knit_artifact_is_bound()
#
# Return 0 when the command bound the named artifact at least once in this
# invocation, 1 otherwise. Consults the per-invocation binding stash filled by
# knit_artifact (_KNIT_CMD_<cmd>_artifact_bound, keyed by normalized name).
#
# @param[in] cmd  Mangled command name.
# @param[in] name Normalized artifact name.
# @return 0 if bound, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_artifact_is_bound() {
    local cmd="$1"
    local name="$2"
    _knit_set_exists "_KNIT_CMD_${cmd}_artifact_bound" || return 1
    # shellcheck disable=SC2178 # nameref to the command's binding stash
    local -n _knit_bound_ref="_KNIT_CMD_${cmd}_artifact_bound"
    [[ -v _knit_bound_ref["${name}"] ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_artifact_check_lower_bound()
#
# Enforce the lower bound of every variadic "+" output the command declared: a
# "name:kind+" collection must bind at least one member. Called at record time,
# after the body (see _knit_artifacts_record_sql), so a "+" output the body left
# unbound is fatal and names the offending output. A "*" output that bound
# nothing is allowed (a fan-out that produced nothing is not an error), and a
# scalar output has no lower bound here (its at-most-once rule lives in
# knit_artifact). Iterates the command's declared artifacts set and consults the
# per-invocation binding stash.
#
# @param[in] cmd       Mangled command name of the producer.
# @param[in] demangled Demangled producer name, used in the fatal message.
# ------------------------------------------------------------------------------
_knit_artifact_check_lower_bound() {
    local cmd="$1"
    local demangled="$2"
    _knit_set_exists "_KNIT_CMD_${cmd}_artifacts" || return 0
    local -a artifacts=()
    _knit_set_array artifacts "_KNIT_CMD_${cmd}_artifacts"
    local name variadic_var kind_var kind
    for name in "${artifacts[@]}"; do
        variadic_var="_KNIT_CMD_${cmd}_artifact_variadic_${name}"
        [[ "${!variadic_var:-}" == "+" ]] || continue
        _knit_artifact_is_bound "${cmd}" "${name}" && continue
        kind_var="_KNIT_CMD_${cmd}_3_${name}_type"
        kind="${!kind_var:-}"
        knit_fatal "Artifact \"${name}\" (kind \"${kind}\", one or more) requires at least one knit_artifact binding, but command \"${demangled}\" bound none."
    done
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
# the name and content digest come from that stash, while the physical type
# ("file" or "directory"), the semantic kind, and the "result" flag are recovered
# from registration state (the fileparam marker holds the physical type, the
# _3_<name>_type field holds the kind, and the results set holds the flag). A
# fresh uuid identifies each artifacts row (the target of its "produced" edge).
# The caller's variable is left empty when the command bound no artifact.
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
    # A "+" output must have bound at least one member; check before the early
    # return below, which would otherwise skip a command that bound nothing.
    _knit_artifact_check_lower_bound "${cmd}" "${producer_name}"
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
    local rel normalized type kind marker marker_var kind_var result aid row_sql edge_sql
    local parts=""
    for rel in "${!_knit_ar_names[@]}"; do
        normalized="${_knit_ar_names[${rel}]}"
        # Recover the physical type ("file"/"directory") from the fileparam marker
        # ("output:<type>:yes"), the semantic kind from registration state, and the
        # result flag from the results set.
        marker_var="_KNIT_CMD_${cmd}_fileparam_${normalized}"
        marker="${!marker_var:-}"
        type="${marker#output:}"
        type="${type%%:*}"
        kind_var="_KNIT_CMD_${cmd}_3_${normalized}_type"
        kind="${!kind_var:-}"
        result=0
        [[ -n "${has_results}" ]] \
            && _knit_set_find "_KNIT_CMD_${cmd}_results" "${normalized}" && result=1
        aid="$(_knit_uuidv7)"
        row_sql="$(_knit_artifacts_row_sql \
            "${aid}" "${rel}" "${normalized}" "${type}" "${kind}" "${_knit_ar_sums[${rel}]}" "${result}")"
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
# @var _KNIT_ARTIFACT_KINDS
#
# Registry mapping each artifact kind name to its backing physical type ("file"
# or "directory"). A kind is an artifact's semantic category (e.g. "csvfile",
# "rundir"); the physical type drives existence checks and checksumming. Seeded
# with the builtin kinds "file" and "directory" (each backed by its own type) and
# the "dir" alias (backed by "directory"), so a bare "name:file" / "name:directory"
# declaration needs no knit_register_artifact call and re-registering one of them
# is fatal. Extended by knit_register_artifact and consulted by
# _knit_artifact_kind_type. Declared global (-g) so it survives being sourced from
# within a function (as the bats tests do). Mirrors _KNIT_RESOURCES / _KNIT_ENUMS.
# ------------------------------------------------------------------------------
declare -gA _KNIT_ARTIFACT_KINDS
_KNIT_ARTIFACT_KINDS=([file]=file [directory]=directory [dir]=directory)

# ------------------------------------------------------------------------------
# @var _KNIT_ARTIFACT_KIND_DESCRIPTIONS
#
# Companion registry mapping each artifact kind name to its one-line description,
# shown by knit describe / --help. Populated alongside _KNIT_ARTIFACT_KINDS; the
# builtin kinds carry a short default description.
# ------------------------------------------------------------------------------
declare -gA _KNIT_ARTIFACT_KIND_DESCRIPTIONS
_KNIT_ARTIFACT_KIND_DESCRIPTIONS=(
    [file]="A single file."
    [directory]="A directory tree."
    [dir]="A directory tree."
)

# ------------------------------------------------------------------------------
# @fn _knit_artifact_kind_type()
#
# Look up the physical type ("file" or "directory") backing an artifact kind and
# store it in the caller-named variable. Returns non-zero when the kind is not
# registered, leaving the variable untouched. Consulted by the output and input
# artifact directives to resolve a declared "name:kind" annotation to its physical
# type.
#
# @param[out] __knit_ret Name of the variable to hold the physical type.
# @param[in]  kind       The artifact kind name.
# @return 0 if the kind is registered, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_artifact_kind_type() {
    local -n __knit_ret=$1
    local kind="$2"
    [[ -v _KNIT_ARTIFACT_KINDS["${kind}"] ]] || return 1
    __knit_ret="${_KNIT_ARTIFACT_KINDS[${kind}]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_artifact_parse_kind()
#
# Split an optional trailing cardinality quantifier off the kind portion of an
# artifact spec (the text after "name:"). A single trailing "*" (zero or more) or
# "+" (one or more) marks the artifact as a variadic collection; a kind with no
# quantifier is scalar. The bare kind (quantifier removed) and the quantifier
# character ("" for scalar, "*", or "+") are stored in the caller's variables.
# Shared by knit_with_output_artifact and knit_with_input_artifact so the syntax
# and its validation cannot drift between the two directions.
#
# A kind carrying more than one trailing quantifier (e.g. "file**" or "file*+")
# is fatal, so a typo is caught at registration rather than silently dropped. The
# bare kind is not validated here (each caller validates it against the kind
# registry as before).
#
# @param[out] __knit_ret1 Name of the variable to hold the bare kind.
# @param[out] __knit_ret2 Name of the variable to hold the quantifier ("", "*", "+").
# @param[in]  raw_kind    The kind portion of the spec (may carry a quantifier).
# @param[in]  context     Caller name, used in the fatal message.
# ------------------------------------------------------------------------------
_knit_artifact_parse_kind() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local raw_kind="$3"
    local context="$4"
    # The working locals are __-prefixed so they cannot shadow a caller that names
    # its output variable "kind" or "quant" (a nameref resolves to the local of
    # the same name, misdirecting the write — see the nameref-shadow gotcha).
    local __knit_bare="${raw_kind}"
    local __knit_quant=""
    case "${__knit_bare}" in
        *[*+])
            __knit_quant="${__knit_bare: -1}"
            __knit_bare="${__knit_bare%?}"
            ;;
    esac
    # Strip one quantifier above; if another still trails, the spec carried more
    # than one, which is malformed.
    case "${__knit_bare}" in
        *[*+])
            knit_fatal "${context}: artifact kind \"${raw_kind}\" may carry at most one trailing quantifier (\"*\" or \"+\")."
            ;;
    esac
    __knit_ret1="${__knit_bare}"
    __knit_ret2="${__knit_quant}"
}

# ------------------------------------------------------------------------------
# @fn knit_register_artifact()
#
# Declare an artifact kind: a semantic category an artifact may carry (e.g.
# "csvfile", "rundir"), backed by a physical type ("file" or "directory"). A
# top-level declaration, like knit_enum — not called between knit_register and
# knit_done. Once declared, a kind may be referenced by knit_with_output_artifact
# and knit_with_input_artifact with the "name:kind" syntax.
#
# The builtin kinds "file", "directory", and the "dir" alias are pre-registered
# (each backed by its matching type), so the common case needs no call here and
# re-registering one of them is fatal.
#
# Example:
# ```
# knit_register_artifact "csvfile:file"     "Tabulated result in CSV format."
# knit_register_artifact "rundir:directory" "A run's output directory."
# ```
#
# @param[in] spec        Kind name followed by ":type" ("file" or "directory").
# @param[in] description Optional one-line description for knit describe / --help.
#
# Fatal when the annotation has no ":type", when the kind name is invalid, when
# the kind is already registered, or when the type is not a checksummable
# ("file"/"directory") type.
# ------------------------------------------------------------------------------
knit_register_artifact() {
    local spec="$1"
    local description="${2:-}"
    if [[ "${spec}" != *:* ]]; then
        knit_fatal "Artifact kind \"${spec}\" is missing a type annotation (expected \"kind:type\")."
    fi
    local kind="${spec%%:*}"
    local type="${spec#*:}"
    if ! _knit_name_is_valid "${kind}"; then
        knit_fatal "Artifact kind \"${kind}\" is not a valid name."
    fi
    if [[ -v _KNIT_ARTIFACT_KINDS["${kind}"] ]]; then
        knit_fatal "Artifact kind \"${kind}\" is already registered."
    fi
    if ! knit_type_exists "${type}"; then
        knit_fatal "Artifact kind \"${kind}\" has unknown type \"${type}\"."
    fi
    if ! _knit_type_is_checksummable "${type}"; then
        knit_fatal "Artifact kind \"${kind}\" must be backed by type \"file\" or \"directory\", not \"${type}\"."
    fi
    local resolved
    _knit_type_resolve_alias resolved "${type}"
    _KNIT_ARTIFACT_KINDS["${kind}"]="${resolved}"
    _KNIT_ARTIFACT_KIND_DESCRIPTIONS["${kind}"]="${description}"
    knit_trace "Registering artifact kind \"${kind}\" (type: ${resolved})."
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
# The artifact name must include a kind annotation using the "name:kind" syntax,
# and the kind must be a registered artifact kind (see knit_register_artifact).
# The builtin kinds "file", "directory", and the "dir" alias are always available;
# a user kind such as "csvfile" is declared once at the top level. The physical
# type behind the kind ("file" or "directory") drives the existence check and the
# checksum, while the kind itself is recorded on the artifacts row.
#
# Example:
# ```
# knit_register "tabulate" "tabulate" "Tabulate results."
# knit_with_output_artifact "table:csvfile" "The results table (CSV)."
# tabulate() {
#    out="$(knit_artifact_dir)"
#    compute > "${out}/table.csv"
#    knit_artifact "table" "table.csv"
# }
# ```
#
# Unlike an ordinary output, an artifact is NOT a column of the command's own
# table. Each binding is recorded at runtime as one row in the framework-owned
# artifacts table (its artifacts-relative path, name, physical type, semantic
# kind, content checksum, and result flag) with a "produced" edge from the
# producing invocation, so a file can be traced back to what made it. The content
# digest is always recorded for an artifact, so there is no --no-checksum opt-out
# here. The artifact is added to the command's artifacts set, and its
# kind/description are kept in registration state so knit describe can report it.
#
# Because a "produced" edge needs the producing invocation's row as its source, a
# command that declares an artifact records an invocation row even if it declared
# no table of its own: a table is ensured automatically at knit_done time.
#
# @param[in] param Artifact name followed by ":kind" (a registered artifact kind).
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
        knit_fatal "Artifact \"${param_spec}\" is missing a kind annotation (expected \"name:kind\")."
    fi
    local param_name="${param_spec%%:*}"
    local param_kind_raw="${param_spec#*:}"
    if ! _knit_name_is_valid "${param_name}"; then
        knit_fatal "Artifact \"${param_name}\" does not have a valid name."
    fi
    # A trailing "*" (zero or more) or "+" (one or more) on the kind marks a
    # variadic collection: the body may bind this name several times. The bare
    # kind drives everything else exactly as a scalar one.
    local param_kind param_quant
    _knit_artifact_parse_kind param_kind param_quant "${param_kind_raw}" "knit_with_output_artifact"
    # The kind drives everything: it must be a registered artifact kind, and its
    # backing physical type ("file"/"directory") feeds the fileparam marker, the
    # runtime existence check, and the checksum.
    local param_type
    if ! _knit_artifact_kind_type param_type "${param_kind}"; then
        knit_fatal "Artifact \"${param_name}\" has unknown kind \"${param_kind}\"."
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
    knit_trace "Adding artifact \"${param_name}\" (kind: ${param_kind}) to command \"${demangled_cmd}\"."
    printf -v "_KNIT_CMD_${cmd}_3_${output}_description" '%s' "$2"
    printf -v "_KNIT_CMD_${cmd}_3_${output}_default"     '%s' ""
    printf -v "_KNIT_CMD_${cmd}_3_${output}_type"        '%s' "${param_kind}"
    # Record the cardinality quantifier ("*"/"+") for a variadic collection so the
    # bind guard, the post-body lower-bound check, and describe can tell a
    # collection from a scalar. A scalar declares no marker.
    if [[ -n "${param_quant}" ]]; then
        printf -v "_KNIT_CMD_${cmd}_artifact_variadic_${output}" '%s' "${param_quant}"
    fi
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
    _knit_set_exists "_KNIT_CMD_${cmd}_artifact_bound" \
        || declare -gA "_KNIT_CMD_${cmd}_artifact_bound=()"
    # shellcheck disable=SC2178 # nameref to the command's binding stash
    local -n names_ref="_KNIT_CMD_${cmd}_artifact_name"
    if [[ -v names_ref["${rel}"] ]]; then
        knit_fatal "Artifact path \"${rel}\" is already recorded for \"${demangled_cmd}\"; artifacts are write-once."
    fi
    # Bind-once for a scalar name. The write-once guard above keys on the PATH, so
    # a scalar name bound to two different paths would otherwise pass silently. A
    # variadic name (declared "name:kind*" / "name:kind+") may bind any number of
    # times; a scalar name may bind at most once.
    local variadic_var="_KNIT_CMD_${cmd}_artifact_variadic_${normalized}"
    # shellcheck disable=SC2178 # nameref to the command's binding stash
    local -n bound_ref="_KNIT_CMD_${cmd}_artifact_bound"
    if [[ -z "${!variadic_var:-}" && -v bound_ref["${normalized}"] ]]; then
        knit_fatal "Artifact \"${name}\" is already bound for \"${demangled_cmd}\"; a scalar artifact binds once (declare it \"${name}:<kind>*\" or \"${name}:<kind>+\" to bind several)."
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
    # fileparam marker holds the alias-resolved physical type as
    # "output:<type>:yes".
    local marker_var="_KNIT_CMD_${cmd}_fileparam_${normalized}"
    local marker="${!marker_var:-}"
    local type="${marker#output:}"
    type="${type%%:*}"
    _knit_checksum_require_exists "${demangled_cmd}" output "${name}" "${type}" "${abs}"
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
    # Mark the name as bound, so a scalar name's bind-once guard fires on a second
    # bind and the post-body "+" lower-bound check sees this name satisfied.
    # shellcheck disable=SC2034 # written through the nameref
    bound_ref["${normalized}"]=1
}

# ------------------------------------------------------------------------------
# @fn knit_input_artifact_path()
#
# Resolve an input-artifact parameter value (an artifacts-relative path) into its
# absolute on-disk location under the experiment's artifacts root and print it to
# stdout. This is how the body of a command that consumes an artifact turns the
# parameter value into a usable path:
#
# ```
# csv="$(knit_input_artifact_path "$(knit_get_parameter input_table "$@")")"
# ```
#
# The value must resolve inside the artifacts root (the same containment rule
# knit_artifact enforces on a produced entry); an absolute path outside it is
# fatal. Fatal too when the value is empty or the resolved entry does not exist,
# since a body should never run against an artifact that is not present. Called at
# most a handful of times per body (one per declared input artifact), so it
# returns via stdout rather than a nameref. Mirrors knit_resource_path.
#
# @param[in] value The input-artifact parameter value (an artifacts-relative path).
# ------------------------------------------------------------------------------
knit_input_artifact_path() {
    local value="$1"
    if [[ -z "${value}" ]]; then
        knit_fatal "knit_input_artifact_path requires an artifact path."
    fi
    local root
    _knit_artifact_root root
    local abs rel
    if ! _knit_artifact_resolve_path abs rel "${root}" "${value}"; then
        knit_fatal "Artifact path \"${value}\" is outside the artifacts directory \"${root}\"."
    fi
    if [[ ! -e "${abs}" && ! -L "${abs}" ]]; then
        knit_fatal "Artifact \"${value}\" not found at \"${abs}\"."
    fi
    printf '%s\n' "${abs}"
}

# ------------------------------------------------------------------------------
# @fn _knit_input_artifact_param_kind()
#
# Store the artifact kind a parameter was declared with in the caller-named
# variable, or the empty string when the parameter is an ordinary parameter (not
# declared through knit_with_input_artifact). Reads the per-parameter marker
# (_KNIT_CMD_<cmd>_input_artifact_<param>) that knit_with_input_artifact records,
# so describe and --help can annotate an input-artifact parameter with its
# required kind from the registration tables alone (no database read). The
# parameter name must be normalized, as it is stored in the parameter sets.
# Mirrors _knit_resource_param_type.
#
# @param[out] __knit_ret Name of the variable to hold the artifact kind (empty if none).
# @param[in] cmd        Mangled command name.
# @param[in] param      Normalized parameter name.
# ------------------------------------------------------------------------------
_knit_input_artifact_param_kind() {
    local -n __knit_ret=$1
    local __var="_KNIT_CMD_${2}_input_artifact_${3}"
    __knit_ret="${!__var:-}"
}

# ------------------------------------------------------------------------------
# @fn _knit_input_artifact_before_cb()
#
# Before-callback installed by knit_with_input_artifact on the consuming command,
# one per declared input-artifact parameter. Before the command body runs it
# resolves the parameter value (an artifacts-relative path) to its row in the
# framework-owned artifacts table and validates it:
#   - the parameter value (the path) missing → fatal;
#   - no artifacts row at that path → fatal (an unbootstrapped experiment has
#     recorded no artifact, so it is treated as a missing row);
#   - the recorded kind not equal to the declared kind → fatal (the physical type
#     is implied by the kind, so it needs no separate check);
#   - when --verify-checksum was declared, the recomputed digest of the resolved
#     entry not equal to the recorded checksum → fatal.
# Returning normally lets the command proceed; a fatal aborts it before the body
# runs.
#
# The declared parameter name, required kind, and verify flag are bound at
# registration time and carried as the first three arguments; the trailing
# arguments are the command's own runtime arguments, scanned for the parameter
# value. Mirrors _knit_resource_dep_before_cb.
#
# @param[in] param  Normalized name of the input-artifact parameter to read.
# @param[in] kind   Artifact kind the resolved artifact must carry.
# @param[in] verify "1" to re-verify the recorded checksum, empty to skip.
# ------------------------------------------------------------------------------
_knit_input_artifact_before_cb() {
    local param="$1"
    local kind="$2"
    local verify="$3"
    shift 3
    local value
    value=$(knit_get_parameter "${param}" "$@") || value=""
    if [[ -z "${value}" ]]; then
        local opt
        _knit_str_underscores_to_hyphens opt "${param}"
        knit_fatal "This command requires an artifact of kind \"${kind}\" (parameter --${opt})."
    fi
    # Resolve the path to its artifacts row. An unbootstrapped experiment has
    # recorded no artifact, so leave the row empty and let the "no artifact" fatal
    # below fire rather than query a database that does not exist.
    local row=""
    if _knit_is_bootstrapped; then
        local tbl esc
        _knit_db_sql_ident tbl "${_KNIT_ARTIFACTS_TABLE}"
        _knit_sql_escape esc "${value}"
        row=$(_knit_sqlite3 -separator '|' \
            "SELECT kind, checksum FROM ${tbl} WHERE path='${esc}' LIMIT 1;" \
            2>/dev/null) || row=""
    fi
    if [[ -z "${row}" ]]; then
        knit_fatal "No artifact recorded at path \"${value}\"; an artifact of kind \"${kind}\" is required."
    fi
    local actual_kind recorded_sum
    IFS='|' read -r actual_kind recorded_sum <<< "${row}"
    if [[ "${actual_kind}" != "${kind}" ]]; then
        knit_fatal "Artifact at \"${value}\" is of kind \"${actual_kind}\", but \"${kind}\" is required."
    fi
    # Opt-in re-verification: re-hash the resolved entry and compare it to the
    # recorded digest, so a silently mutated artifact is caught before the body runs.
    if [[ -n "${verify}" ]]; then
        local path
        path="$(knit_input_artifact_path "${value}")"
        local hex
        _knit_sha256 hex "${path}" \
            || knit_fatal "Could not checksum artifact \"${value}\" for verification."
        if [[ "sha256:${hex}" != "${recorded_sum}" ]]; then
            knit_fatal "Artifact at \"${value}\" failed checksum verification: recorded \"${recorded_sum}\", got \"sha256:${hex}\"."
        fi
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_input_artifact_record_used_by_edge()
#
# Record a "used_by" provenance edge from a consumed artifact to a consuming
# invocation. The edge's source is the artifacts row (its id resolved by path,
# its node name the "artifacts" label — the same node the "produced" edge points
# at, so lineage joins as A --produced--> artifact --used_by--> B); its target is
# the consumer. Delegates the gated write to _knit_record_used_by_edge, so it
# records nothing when recording is disabled, on a suppressed rank, before
# bootstrap, when the target does not participate in the graph, or when no row is
# found at the path (empty id -> no edge). Mirrors
# _knit_resource_record_used_by_edge.
#
# @param[in] value      Artifacts-relative path of the consumed artifact.
# @param[in] target_cmd Mangled command name of the consumer (the edge target).
# @param[in] target_id  Resolved row id of the consumer (the edge target).
# ------------------------------------------------------------------------------
_knit_input_artifact_record_used_by_edge() {
    local value="$1"
    local target_cmd="$2"
    local target_id="$3"
    # Resolve the artifacts row id by path. An unbootstrapped experiment has no
    # database to read, so leave the id empty and let the gated edge writer drop
    # the edge rather than query a database that does not exist.
    local artifact_id=""
    if _knit_is_bootstrapped; then
        local tbl esc
        _knit_db_sql_ident tbl "${_KNIT_ARTIFACTS_TABLE}"
        _knit_sql_escape esc "${value}"
        artifact_id=$(_knit_sqlite3 \
            "SELECT id FROM ${tbl} WHERE path='${esc}' LIMIT 1;" \
            2>/dev/null) || artifact_id=""
    fi
    _knit_record_used_by_edge "${artifact_id}" "${_KNIT_ARTIFACTS_TABLE}" \
        "${target_cmd}" "${target_id}"
}

# ------------------------------------------------------------------------------
# @fn _knit_input_artifact_after_cb()
#
# After-callback installed by knit_with_input_artifact on the consuming command,
# one per declared input-artifact parameter. It records a "used_by" edge from the
# consumed artifact to the command itself. It runs as an after-callback (not the
# before-callback that validates the artifact) because the consumer's frame is on
# the executing stacks only from push time onward, so the consumer's resolved row
# id — the edge target — is available here but not in the before-callback (this
# mirrors _knit_resource_dep_after_cb).
#
# The declared parameter name, required kind, and verify flag are bound at
# registration time and carried as the first three arguments (only the parameter
# name is used here; the kind and verify flag are kept for symmetry with the
# before-callback's bound arguments); the trailing arguments are the command's own
# runtime arguments, scanned for the parameter value. A missing value is silently
# skipped: the before-callback already fataled on it, so this is only reached with
# a valid value.
#
# @param[in] param Normalized name of the input-artifact parameter to read.
# ------------------------------------------------------------------------------
_knit_input_artifact_after_cb() {
    local param="$1"
    shift 3
    local value
    value=$(knit_get_parameter "${param}" "$@") || value=""
    [[ -z "${value}" ]] && return 0
    [[ ${#_KNIT_EXECUTING_COMMAND[@]} -gt 0 ]] || return 0
    _knit_input_artifact_record_used_by_edge "${value}" \
        "${_KNIT_EXECUTING_COMMAND[-1]}" "${_KNIT_EXECUTING_ROW_ID[-1]}"
}

# ------------------------------------------------------------------------------
# @fn knit_with_input_artifact()
#
# Declare that the command currently being registered consumes a recorded
# artifact of a given kind, given as `"name:kind"` (e.g. "input_table:csvfile").
# Must be called between a knit_register* call and knit_done; a command may
# declare several input artifacts. The `kind` must be a registered artifact kind
# (see knit_register_artifact); the builtin kinds "file", "directory", and the
# "dir" alias are always available. It is the consuming counterpart of
# knit_with_output_artifact.
#
# Under the hood (mirroring knit_with_resource) this registers an ordinary
# required string parameter named `name` whose value is the artifact's
# artifacts-relative path, so the CLI, knit_get_parameter, and the backing table
# all treat it as a plain value; the command body turns that path into an on-disk
# location with knit_input_artifact_path. A per-parameter marker
# (_KNIT_CMD_<cmd>_input_artifact_<param>=<kind>) records the required kind, and a
# companion _input_artifact_verify_<param> marker records the --verify-checksum
# opt-in; both are read by the validation before-callback and, later, by describe
# / --help. A before-callback resolves the path to the artifacts row and validates
# it (existence + kind, plus an opt-in checksum re-verification) before the body
# runs, and an after-callback records a "used_by" provenance edge from the consumed
# artifact to this command.
#
# ```
# knit_register "plot" plot "Plot a results table."
# knit_with_input_artifact "input_table:csvfile" "The table to plot." --verify-checksum
# plot() {
#     local csv
#     csv="$(knit_input_artifact_path "$(knit_get_parameter input_table "$@")")"
#     gnuplot -e "..." "${csv}"
# }
# knit_done
# ```
#
# Invoked as: `./exp.sh plot --input-table tables/run7.csv`.
#
# Wrappers cannot declare knit_with_input_artifact (they forward their arguments
# verbatim and take no parsed parameters). Every declared input artifact is
# required.
#
# @param[in] spec        The dependency as "name:kind" (a registered artifact kind).
# @param[in] description One-line description of the input-artifact parameter.
# @param[in] --verify-checksum Optional flag; re-verify the recorded checksum before
#        the body runs.
# ------------------------------------------------------------------------------
knit_with_input_artifact() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_input_artifact must be called between a knit_register* call and knit_done."
    fi
    _knit_wrapper_reject_declaration "knit_with_input_artifact"
    knit_check_arguments "" "verify-checksum" "${@:3}" \
        || knit_fatal "knit_with_input_artifact takes an artifact, a description, and an optional --verify-checksum."

    local spec="$1"
    local description="$2"
    if [[ "${spec}" != *:* ]]; then
        knit_fatal "knit_with_input_artifact requires a \"name:kind\" annotation; got \"${spec}\"."
    fi
    local param_name="${spec%%:*}"
    local param_kind="${spec#*:}"
    if [[ -z "${param_name}" ]] || ! _knit_name_is_valid "${param_name}"; then
        knit_fatal "knit_with_input_artifact: \"${param_name}\" is not a valid parameter name."
    fi
    if [[ -z "${param_kind}" ]]; then
        knit_fatal "knit_with_input_artifact requires an artifact kind after the colon; got \"${spec}\"."
    fi
    # The kind must be a registered artifact kind (builtins included). The physical
    # type it is backed by is implied by the kind, so it needs no separate check.
    local param_type
    if ! _knit_artifact_kind_type param_type "${param_kind}"; then
        knit_fatal "knit_with_input_artifact references unknown artifact kind \"${param_kind}\"; register it with knit_register_artifact first."
    fi

    local cmd="${_KNIT_CURRENT_COMMAND}"
    local param
    param=$(_knit_name_normalize "${param_name}")

    # Record the required kind in a per-parameter marker, read by the validation
    # before-callback and (later) by describe / --help.
    printf -v "_KNIT_CMD_${cmd}_input_artifact_${param}" '%s' "${param_kind}"
    # Record the --verify-checksum opt-in in a companion marker.
    local verify=""
    if _knit_decl_flag_present "verify-checksum" "${@:3}"; then
        verify="1"
        printf -v "_KNIT_CMD_${cmd}_input_artifact_verify_${param}" '%s' "1"
    fi

    # Register the underlying required string parameter whose value is the
    # artifact's artifacts-relative path, the before-callback that validates the
    # named artifact before the body runs, and the after-callback that records the
    # "used_by" provenance edge from the artifact to this command. Every input
    # artifact is required.
    [[ -z "${description}" ]] && description="Input artifact of kind \"${param_kind}\"."
    knit_with_required "${param_name}:string" "${description}"
    _knit_run_before _knit_input_artifact_before_cb "${param}" "${param_kind}" "${verify}"
    _knit_run_after _knit_input_artifact_after_cb "${param}" "${param_kind}" "${verify}"
}
