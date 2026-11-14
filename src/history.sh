#!/bin/bash

## @file history.sh

# ------------------------------------------------------------------------------
# @var _KNIT_HISTORY_TABLE
#
# Name of the framework-owned table that records the top-level commands the user
# invoked (the root invocations), time-ordered by their UUIDv7 ids, for replay
# and audit. The "__" prefix/suffix marks it as reserved (not a user-provided
# command table), like other reserved names.
# ------------------------------------------------------------------------------
declare -g _KNIT_HISTORY_TABLE
_KNIT_HISTORY_TABLE="__history__"

# ------------------------------------------------------------------------------
# @var _KNIT_HISTORY_TABLE_ENSURED
#
# Set to "1" once the history table has been ensured in this process (see
# _knit_history_ensure_table), so the idempotent CREATE runs at most once per run.
# ------------------------------------------------------------------------------
declare -g _KNIT_HISTORY_TABLE_ENSURED
_KNIT_HISTORY_TABLE_ENSURED=""

# ------------------------------------------------------------------------------
# @fn _knit_history_create_table()
#
# Create the history table if it does not already exist. Each row is one
# top-level user invocation (a root command, with no provenance source): a stable
# "id" (the invocation's uuidv7, whose embedded timestamp orders rows in time),
# the demangled "command" name in colon notation ("submit", "submit:drain",
# "metadata:store"), the command line in two forms -- "invoked" (the raw tokens
# the user typed) and "resolved" (the same after optional defaults, flags, and
# "ENV[...]" defaults are expanded) -- each a JSON array of tokens, the
# "start_time"/"end_time" as REAL epoch seconds, and the body's "exit_status"
# (NULL when unknown, e.g. a command that opts out of exit tracking). Called at
# bootstrap alongside the metadata and __provenance__ tables.
# ------------------------------------------------------------------------------
_knit_history_create_table() {
    local history_ident
    _knit_db_sql_ident history_ident "${_KNIT_HISTORY_TABLE}"
    _knit_sqlite3_write <<EOF
CREATE TABLE IF NOT EXISTS ${history_ident} (
    id           TEXT,
    command      TEXT,
    invoked      TEXT,
    resolved     TEXT,
    start_time   REAL,
    end_time     REAL,
    exit_status  INTEGER
);
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_history_ensure_table()
#
# Ensure the history table exists before a history row is written, creating it
# lazily on first use. A freshly bootstrapped experiment already has the table
# (created at bootstrap); a database bootstrapped before this feature shipped does
# not, so ensuring it here lets a new invocation record history rather than
# failing. The create is idempotent and runs at most once per process, guarded by
# _KNIT_HISTORY_TABLE_ENSURED. Mirrors _knit_prov_ensure_table.
# ------------------------------------------------------------------------------
_knit_history_ensure_table() {
    [[ -n "${_KNIT_HISTORY_TABLE_ENSURED}" ]] && return 0
    _knit_history_create_table
    _KNIT_HISTORY_TABLE_ENSURED="1"
}

# ------------------------------------------------------------------------------
# @var _KNIT_EXECUTING_INVOKED
#
# Flat array holding the raw, as-invoked argument tokens of every invocation
# frame currently on the executing stack, concatenated in push order. A frame's
# own slice is recovered with the per-frame token count stored in
# _KNIT_EXECUTING_INVOKED_LEN. Storing the tokens in a real array (rather than a
# serialized scalar) keeps the hot path fork-free: no token ever needs escaping
# or re-parsing, and a root's invoked line is read back exactly as typed.
# ------------------------------------------------------------------------------
declare -ga _KNIT_EXECUTING_INVOKED=()

# ------------------------------------------------------------------------------
# @var _KNIT_EXECUTING_INVOKED_LEN
#
# Stack parallel to _KNIT_EXECUTING_COMMAND: entry i holds the number of tokens
# frame i contributed to _KNIT_EXECUTING_INVOKED, so the top frame's as-invoked
# argument slice is the last _KNIT_EXECUTING_INVOKED_LEN[-1] elements of the flat
# array. Pushed by _knit_history_push_frame and popped by _knit_history_pop_frame
# in lockstep with the other executing stacks.
# ------------------------------------------------------------------------------
declare -ga _KNIT_EXECUTING_INVOKED_LEN=()

# ------------------------------------------------------------------------------
# @fn _knit_history_push_frame()
#
# Push an invocation frame's raw, as-invoked argument tokens onto the flat
# history stack, recording the token count so the slice can be recovered and
# removed again. Called from _knit_invoke_command alongside the other executing
# stacks (wrapper and normal paths), with the raw (pre-expansion) arguments.
#
# @param[in] ... The raw argument tokens the user typed for this frame.
# ------------------------------------------------------------------------------
_knit_history_push_frame() {
    _KNIT_EXECUTING_INVOKED_LEN+=("$#")
    _KNIT_EXECUTING_INVOKED+=("$@")
}

# ------------------------------------------------------------------------------
# @fn _knit_history_pop_frame()
#
# Pop the top invocation frame off the flat history stack, dropping its token
# slice from _KNIT_EXECUTING_INVOKED and its count from
# _KNIT_EXECUTING_INVOKED_LEN. Called from _knit_invoke_command alongside the
# other executing-stack pops. A no-op when the stack is empty (defensive).
# ------------------------------------------------------------------------------
_knit_history_pop_frame() {
    local depth=${#_KNIT_EXECUTING_INVOKED_LEN[@]}
    (( depth == 0 )) && return 0
    local n="${_KNIT_EXECUTING_INVOKED_LEN[-1]}"
    unset '_KNIT_EXECUTING_INVOKED_LEN[-1]'
    local total=${#_KNIT_EXECUTING_INVOKED[@]}
    _KNIT_EXECUTING_INVOKED=("${_KNIT_EXECUTING_INVOKED[@]:0:total-n}")
}

# ------------------------------------------------------------------------------
# @fn _knit_history_json_array()
#
# Serialize a bash array of argument tokens to a compact JSON array, returned
# through a nameref. The tokens are fed to knit_jq NUL-delimited on stdin (not as
# "--args", which jq would misread for any token that begins with "-", e.g. an
# option like "--size"); a NUL cannot appear inside an argument token, so the
# split is exact for any content. An empty array is rendered directly as "[]",
# since a lone "printf '%s\0'" with no arguments still emits one NUL. Best-effort:
# returns non-zero (leaving the output untouched) if jq is unavailable or fails,
# with its diagnostics suppressed, so a recording failure never pollutes a
# command's output; the caller then skips the row.
#
# @param[out] __knit_ret The compact JSON array string.
# @param[in]  tokens     Name of the array of tokens to serialize.
# ------------------------------------------------------------------------------
_knit_history_json_array() {
    local -n __knit_ret="$1"
    local -n _knit_ja_tokens="$2"
    if [[ ${#_knit_ja_tokens[@]} -eq 0 ]]; then
        __knit_ret='[]'
        return 0
    fi
    local json
    json="$(printf '%s\0' "${_knit_ja_tokens[@]}" \
        | knit_jq -Rsc 'split("\u0000")[:-1]' 2>/dev/null)" || return 1
    [[ -n "${json}" ]] || return 1
    __knit_ret="${json}"
}

# ------------------------------------------------------------------------------
# @fn _knit_history_insert()
#
# Insert one row into the history table. The two argument forms are already
# serialized JSON token arrays; the timestamps and exit status are nullable
# (empty -> NULL). The write is serialized through _knit_sqlite3_write like every
# other write path.
#
# @param[in] id            The invocation's uuidv7 (the row id).
# @param[in] command       The demangled command name in colon notation.
# @param[in] start_time    Epoch seconds when the body started (empty -> NULL).
# @param[in] end_time      Epoch seconds when the body returned (empty -> NULL).
# @param[in] exit_status   The body's exit status (empty -> NULL).
# @param[in] invoked_json  JSON array of the raw, as-invoked tokens.
# @param[in] resolved_json JSON array of the expanded, as-resolved tokens.
# ------------------------------------------------------------------------------
_knit_history_insert() {
    local id="$1"
    local command="$2"
    local start_time="$3"
    local end_time="$4"
    local exit_status="$5"
    local invoked_json="$6"
    local resolved_json="$7"

    local tbl esc_id esc_cmd esc_inv esc_res
    _knit_db_sql_ident tbl "${_KNIT_HISTORY_TABLE}"
    _knit_sql_escape esc_id "${id}"
    _knit_sql_escape esc_cmd "${command}"
    _knit_sql_escape esc_inv "${invoked_json}"
    _knit_sql_escape esc_res "${resolved_json}"

    _knit_sqlite3_write <<EOF
INSERT INTO ${tbl} (id, command, invoked, resolved, start_time, end_time, exit_status)
VALUES ('${esc_id}', '${esc_cmd}', '${esc_inv}', '${esc_res}', $(_knit_prov_nullable_literal "${start_time}"), $(_knit_prov_nullable_literal "${end_time}"), $(_knit_prov_nullable_literal "${exit_status}"));
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_history_record()
#
# Record one history row for the current invocation, but only when it is a
# top-level user invocation (a root: no provenance source) of a
# provenance-participating command. Called from _knit_invoke_command's
# after-phase while the frame is still on the executing stacks, separately from
# _knit_record_invocation so the data-row dedup (the eager "knit submit" record
# path) cannot short-circuit it, and with the body's exit status and end time
# already known.
#
# The resolved (expanded) argument form is passed in by the caller; the invoked
# (raw) form is read from the flat history stack. Gated like the other recording
# writes: disabled globally by KNIT_DISABLE_RECORDING, suppressed on non-root
# ranks of a run, and skipped until the experiment is bootstrapped.
#
# @param[in] cmd  The mangled command name of this frame.
# @param[in] ...  The resolved (expanded) argument tokens of this frame.
# ------------------------------------------------------------------------------
_knit_history_record() {
    local cmd="$1"
    shift
    # shellcheck disable=SC2034 # passed by name to _knit_history_json_array (nameref).
    local -a resolved=("$@")

    [[ "${KNIT_DISABLE_RECORDING:-}" == "true" ]] && return 0
    [[ -n "${_KNIT_RECORDING_SUPPRESSED}" ]] && return 0
    _knit_is_bootstrapped || return 0

    # Only a provenance-participating command appears in the history; a hidden or
    # knit_without_provenance command is transparent here, as it is to the graph.
    _knit_provenance_enabled "${cmd}" || return 0

    # Root only: a non-empty source means an in-process caller or a context
    # carried across a process boundary (knit_resolve_source_context), i.e. an
    # indirect invocation, which the history excludes.
    local source_id source_name
    _knit_resolve_source_context source_id source_name
    [[ -n "${source_id}" || -n "${source_name}" ]] && return 0

    # The invoked form is this frame's slice at the top of the flat stack.
    local depth=${#_KNIT_EXECUTING_INVOKED_LEN[@]}
    (( depth == 0 )) && return 0
    local n="${_KNIT_EXECUTING_INVOKED_LEN[-1]}"
    local total=${#_KNIT_EXECUTING_INVOKED[@]}
    # shellcheck disable=SC2034 # passed by name to _knit_history_json_array (nameref).
    local -a invoked=("${_KNIT_EXECUTING_INVOKED[@]:total-n:n}")

    # Serialize both forms first; a serialization failure (e.g. jq unavailable) is
    # best-effort — skip the row rather than pollute the command's output.
    local invoked_json resolved_json
    _knit_history_json_array invoked_json invoked || return 0
    _knit_history_json_array resolved_json resolved || return 0

    local id="${_KNIT_EXECUTING_ROW_ID[-1]}"
    local start_time=""
    [[ ${#_KNIT_EXECUTING_START_TIME[@]} -gt 0 ]] && start_time="${_KNIT_EXECUTING_START_TIME[-1]}"
    local end_time="${_KNIT_INVOCATION_END_TIME}"
    [[ -z "${end_time}" ]] && end_time="$(_knit_prov_now)"
    local exit_status="${_KNIT_INVOCATION_EXIT_STATUS}"

    local command
    command="$(_knit_command_demangle "${cmd}")"

    _knit_history_ensure_table
    _knit_history_insert "${id}" "${command}" "${start_time}" "${end_time}" \
        "${exit_status}" "${invoked_json}" "${resolved_json}"
}
