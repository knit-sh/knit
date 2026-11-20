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
# split is exact for any content. The trailing NUL is stripped (rtrimstr) before
# the split so the result does not depend on whether a given jq keeps or drops
# the empty field a trailing delimiter would otherwise produce. An empty array is
# rendered directly as "[]", since a lone "printf '%s\0'" with no arguments still
# emits one NUL. Best-effort:
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
        | knit_jq -Rsc 'rtrimstr("\u0000") | split("\u0000")' 2>/dev/null)" || return 1
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
# top-level user invocation (a root: no provenance source) of a history-eligible
# command (knit_with_history / knit_without_history — see _knit_history_enabled;
# an independent axis from provenance). Called from _knit_invoke_command's
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
    # Record nothing while the bootstrap command itself runs: bootstrap provisions
    # the experiment (and makes many internal metadata writes); it is
    # infrastructure, not an experiment action, so it stays out of the history
    # (a "knit history show" replay assumes an already-bootstrapped experiment).
    # bootstrap remains a normal provenance node, so its nested calls stay
    # non-root regardless.
    [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0

    # Only a history-eligible command appears in the history: an independent
    # recording axis from provenance (a command may record no provenance edge yet
    # still belong in the replayable history, e.g. "metadata store", or vice
    # versa). Eligibility defaults on and is turned off with knit_without_history.
    _knit_history_enabled "${cmd}" || return 0

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

# ------------------------------------------------------------------------------
# @fn _knit_history_json_to_tokens()
#
# Parse a stored JSON token array back into a bash array, returned through a
# nameref. The inverse of _knit_history_json_array: jq emits each element
# NUL-terminated so a token that itself contains a newline (or any byte but NUL,
# which an argument cannot hold) is restored exactly. An empty or "[]" input
# yields an empty array. Best-effort/quiet: a jq failure leaves the array empty.
#
# @param[out] __knit_ret_arr The array to fill with the tokens.
# @param[in]  json           The compact JSON array string to parse.
# ------------------------------------------------------------------------------
_knit_history_json_to_tokens() {
    local -n __knit_ret_arr="$1"
    local json="$2"
    __knit_ret_arr=()
    [[ -z "${json}" || "${json}" == "[]" ]] && return 0
    mapfile -d '' -t __knit_ret_arr < <(printf '%s' "${json}" \
        | knit_jq -j '.[] + "\u0000"' 2>/dev/null)
}

# ------------------------------------------------------------------------------
# @fn _knit_history_render_line()
#
# Render one history entry as a command line: the command name with its nesting
# colons turned to spaces (as the user types it at the shell), followed by the
# argument tokens minimally shell-quoted (via _knit_str_render_cmd, so only
# tokens that need it are quoted). Returned through a nameref.
#
# @param[out] __knit_ret The rendered "command args..." line.
# @param[in]  command    The stored command name in colon notation.
# @param[in]  json       The JSON token array (invoked or resolved) to render.
# ------------------------------------------------------------------------------
_knit_history_render_line() {
    local -n __knit_ret="$1"
    local command="$2"
    local json="$3"
    local -a _knit_hrl_tokens
    _knit_history_json_to_tokens _knit_hrl_tokens "${json}"
    local path="${command//:/ }"
    local rendered=""
    (( ${#_knit_hrl_tokens[@]} )) && rendered="$(_knit_str_render_cmd _knit_hrl_tokens)"
    __knit_ret="${path}${rendered:+ ${rendered}}"
}

# ------------------------------------------------------------------------------
# @fn _knit_history_flags_json()
#
# Build a JSON array of the flag (boolean) option names a command declared, used
# by the JSON formatter to tell a flag from a value-bearing option. Read from the
# live registration (_KNIT_CMD_<mangled>_flags); a command no longer registered,
# or one with no flags, yields "[]". Flag names are plain identifiers
# ([A-Za-z0-9_-]), so the array is built directly without escaping.
#
# @param[out] __knit_ret The JSON array of flag names (e.g. '["verbose"]').
# @param[in]  command    The command name in colon notation.
# ------------------------------------------------------------------------------
_knit_history_flags_json() {
    local -n __knit_ret="$1"
    local command="$2"
    local mangled="${command//:/__1__}"
    local set_var="_KNIT_CMD_${mangled}_flags"
    local out="[" sep="" f
    if declare -p "${set_var}" >/dev/null 2>&1; then
        while IFS= read -r f; do
            [[ -z "${f}" ]] && continue
            out+="${sep}\"${f}\""
            sep=","
        done < <(_knit_set_iter "${set_var}")
    fi
    out+="]"
    __knit_ret="${out}"
}

# ------------------------------------------------------------------------------
# @fn _knit_history_show_json()
#
# Emit the history as a JSON array of {name, args, extra} objects, one per
# invocation in time order. "name" is the command in colon notation; "args" is
# the map of options before "--" (a value-bearing option maps to its string
# value, a flag to a boolean); "extra" is the list of tokens after "--" (the
# dispatched target and its arguments). The per-row token array, the command's
# flag set, and the command name are fed to a single jq pass that does the
# decomposition, so the flag/option distinction follows the live registration.
#
# @param[in] sql      A "SELECT id, command, start_time, exit_status, <col> ..."
#            statement selecting the (already filtered and ordered) rows.
# @param[in] annotate "true" to add id/time/exit fields to each object.
# ------------------------------------------------------------------------------
_knit_history_show_json() {
    local sql="$1"
    local annotate="$2"
    local input="" id command start exitv tokens flags_json
    while IFS='|' read -r id command start exitv tokens; do
        [[ -z "${command}" ]] && continue
        _knit_history_flags_json flags_json "${command}"
        input+="$(printf '{"command":"%s","tokens":%s,"flags":%s,"id":"%s","start":%s,"exit":%s}' \
            "${command}" "${tokens}" "${flags_json}" "${id}" "${start:-null}" "${exitv:-null}")"$'\n'
    done < <(_knit_sqlite3 "${sql}")

    if [[ -z "${input}" ]]; then
        printf '[]\n'
        return 0
    fi

    local annotate_json="false"
    [[ "${annotate}" == "true" ]] && annotate_json="true"

    # Per row: split the token array at the first "--" into the option head and
    # the extra tail; fold the head into an args object (a flag -> boolean, an
    # option -> its string value), carrying a pending option key across the token
    # that holds its value. With --annotate, add the id, the time (start as an
    # ISO-8601 string), and the exit status.
    # shellcheck disable=SC2016 # $name/$flags/$toks are jq variables, not shell.
    local prog='map(
      .command as $name | .flags as $flags | .tokens as $toks
      | .id as $id | .start as $start | .exit as $exit
      | ($toks | index("--")) as $sep
      | (if $sep == null then $toks else $toks[0:$sep] end) as $head
      | (if $sep == null then [] else $toks[$sep+1:] end) as $extra
      | (reduce $head[] as $t ({args:{}, key:null, isflag:false};
          if ($t | startswith("--")) then
            (if .key != null then .args[.key] = true else . end)
            | ($t | ltrimstr("--")) as $raw
            | if ($raw | contains("=")) then
                ($raw | split("=")) as $kv
                | .args[$kv[0]] = ($kv[1:] | join("=")) | .key = null | .isflag = false
              else
                .key = $raw | .isflag = (($flags | index($raw)) != null)
              end
          else
            if .key == null then .
            elif .isflag then .args[.key] = ($t == "true") | .key = null | .isflag = false
            else .args[.key] = $t | .key = null | .isflag = false
            end
          end)) as $r
      | ($r | if .key != null then .args[.key] = true else . end) as $r2
      | {name: $name, args: $r2.args, extra: $extra}
      | if $annotate then . + {
          id: $id,
          time: (if $start == null then null else ($start | todate) end),
          exit: $exit
        } else . end
    )'
    printf '%s' "${input}" | knit_jq -s --argjson annotate "${annotate_json}" "${prog}" 2>/dev/null \
        || printf '[]\n'
}

# ------------------------------------------------------------------------------
# @fn _knit_history_command_clause()
#
# Build the SQL predicate for a "--command" selector list (comma-separated, colon
# notation): a bare selector matches that command exactly; a ":*" suffix matches
# the command and all of its subcommands. Selectors are OR-ed. Subcommand
# matching uses GLOB (not LIKE) so an underscore in a command name is a literal,
# not a wildcard. Returns the empty string for an empty selector list.
#
# @param[out] __knit_ret The predicate (without surrounding parentheses), or "".
# @param[in]  spec       The raw "--command" value.
# ------------------------------------------------------------------------------
_knit_history_command_clause() {
    local -n __knit_ret="$1"
    local spec="$2"
    local -a selectors=()
    local IFS=','
    read -ra selectors <<< "${spec}"
    local -a parts=()
    local sel base esc
    for sel in "${selectors[@]}"; do
        [[ -z "${sel}" ]] && continue
        if [[ "${sel}" == *":*" ]]; then
            base="${sel%:\*}"
            _knit_sql_escape esc "${base}"
            parts+=("command = '${esc}'")
            _knit_sql_escape esc "${base}:*"
            parts+=("command GLOB '${esc}'")
        else
            _knit_sql_escape esc "${sel}"
            parts+=("command = '${esc}'")
        fi
    done
    # Distinct name (not "clause"): a caller passes its own "clause" variable as
    # this function's output nameref, so a local "clause" here would shadow it.
    local __knit_hcc_clause="" p
    for p in "${parts[@]}"; do
        [[ -z "${__knit_hcc_clause}" ]] && __knit_hcc_clause="${p}" || __knit_hcc_clause+=" OR ${p}"
    done
    __knit_ret="${__knit_hcc_clause}"
}

# ------------------------------------------------------------------------------
# @fn _knit_history_bound_clause()
#
# Build the SQL predicate for a "--since"/"--until" bound. A value shaped like a
# UUID is compared against the row id (which is time-ordered, being a UUIDv7);
# any other value is parsed as a date/time (via date(1), accepting ISO-8601) and
# compared against start_time. Fatal on an unparseable time.
#
# @param[out] __knit_ret The predicate.
# @param[in]  value      The bound value (a UUID or a timestamp).
# @param[in]  op         The comparison operator (">=" for --since, "<" for --until).
# ------------------------------------------------------------------------------
_knit_history_bound_clause() {
    local -n __knit_ret="$1"
    local value="$2"
    local op="$3"
    local esc
    if [[ "${value}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        _knit_sql_escape esc "${value}"
        __knit_ret="id ${op} '${esc}'"
    else
        local epoch
        epoch="$(date -d "${value}" +%s 2>/dev/null)" \
            || knit_fatal "history show: cannot parse time \"${value}\" (expected a UUID or an ISO-8601 timestamp)."
        __knit_ret="start_time ${op} ${epoch}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_history_row_sql()
#
# Build the SELECT that returns "command, <col>" for the filtered, ordered rows a
# "knit history show" invocation should render. Applies --status (default
# success), --command, --since/--until, --id, and --first/--last. Rows are ordered
# oldest-first (start_time, id); --last takes the N most recent while keeping that
# order via a subquery. --first and --last are mutually exclusive.
#
# @param[out] __knit_ret The complete SELECT statement.
# @param[in]  col        The token column to select ("invoked" or "resolved").
# @param[in]  ...        The expanded invocation arguments (filters).
# ------------------------------------------------------------------------------
_knit_history_row_sql() {
    local -n __knit_ret="$1"
    local col="$2"
    shift 2

    local status command_sel since_val until_val id_val first_val last_val
    status="$(knit_get_parameter "status" "$@")"      || status="success"
    command_sel="$(knit_get_parameter "command" "$@")" || command_sel=""
    since_val="$(knit_get_parameter "since" "$@")"     || since_val=""
    until_val="$(knit_get_parameter "until" "$@")"     || until_val=""
    id_val="$(knit_get_parameter "id" "$@")"           || id_val=""
    first_val="$(knit_get_parameter "first" "$@")"     || first_val=""
    last_val="$(knit_get_parameter "last" "$@")"       || last_val=""

    if [[ -n "${first_val}" && -n "${last_val}" ]]; then
        knit_fatal "history show: --first and --last are mutually exclusive."
    fi

    local -a conds=()
    case "${status}" in
        success) conds+=("exit_status = 0") ;;
        failure) conds+=("exit_status <> 0") ;;
        all)     ;;
    esac
    if [[ -n "${id_val}" ]]; then
        local esc; _knit_sql_escape esc "${id_val}"
        conds+=("id = '${esc}'")
    fi
    if [[ -n "${command_sel}" ]]; then
        local clause; _knit_history_command_clause clause "${command_sel}"
        [[ -n "${clause}" ]] && conds+=("(${clause})")
    fi
    if [[ -n "${since_val}" ]]; then
        local c; _knit_history_bound_clause c "${since_val}" ">="
        conds+=("${c}")
    fi
    if [[ -n "${until_val}" ]]; then
        local c; _knit_history_bound_clause c "${until_val}" "<"
        conds+=("${c}")
    fi

    local where="" cond
    for cond in "${conds[@]}"; do
        [[ -z "${where}" ]] && where="WHERE ${cond}" || where+=" AND ${cond}"
    done

    # Columns, in read order: the token column (invoked/resolved) is last so a
    # token containing the "|" field separator is absorbed by the final field.
    local cols="id, command, start_time, exit_status, ${col}"
    local tbl="${_KNIT_HISTORY_TABLE}"
    if [[ -n "${last_val}" ]]; then
        __knit_ret="SELECT ${cols} FROM (SELECT ${cols} FROM ${tbl} ${where} ORDER BY start_time DESC, id DESC LIMIT ${last_val}) ORDER BY start_time, id;"
    elif [[ -n "${first_val}" ]]; then
        __knit_ret="SELECT ${cols} FROM ${tbl} ${where} ORDER BY start_time, id LIMIT ${first_val};"
    else
        __knit_ret="SELECT ${cols} FROM ${tbl} ${where} ORDER BY start_time, id;"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_history_emit()
#
# Emit the history to standard output in the requested format. For "default" and
# "bash", one line per invocation (bash prefixes a shebang and "./<script>");
# with --annotate, each line is preceded by a "# <id>  <iso-time>  (exit N)"
# comment. For "json", delegate to _knit_history_show_json. An absent table
# (a database predating this feature) is an empty history (an empty JSON array
# for the JSON format).
#
# @param[in] format    "default", "bash", or "json".
# @param[in] annotate  "true" to prefix id/time/exit annotations.
# @param[in] has_table Non-empty when the history table exists.
# @param[in] sql       The filtered/ordered row SELECT (empty when no table).
# ------------------------------------------------------------------------------
_knit_history_emit() {
    local format="$1" annotate="$2" has_table="$3" sql="$4"

    if [[ -z "${has_table}" ]]; then
        [[ "${format}" == "json" ]] && printf '[]\n'
        return 0
    fi

    if [[ "${format}" == "json" ]]; then
        _knit_history_show_json "${sql}" "${annotate}"
        return 0
    fi

    [[ "${format}" == "bash" ]] && printf '#!/usr/bin/env bash\n'

    local id command start exitv tokens line iso
    while IFS='|' read -r id command start exitv tokens; do
        [[ -z "${command}" ]] && continue
        _knit_history_render_line line "${command}" "${tokens}"
        if [[ "${annotate}" == "true" ]]; then
            iso=""
            if [[ -n "${start}" ]]; then
                iso="$(date -u -d "@${start%.*}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || iso=""
            fi
            printf '# %s  %s  (exit %s)\n' "${id}" "${iso}" "${exitv:-?}"
        fi
        case "${format}" in
            bash) printf './%s %s\n' "${KNIT_SCRIPT_NAME}" "${line}" ;;
            *)    printf '%s\n' "${line}" ;;
        esac
    done < <(_knit_sqlite3 "${sql}")
}

# ------------------------------------------------------------------------------
# @fn _knit_history_show()
#
# Body of "knit history show": print the recorded top-level user invocations in
# time order (by start_time, then id). "--format default" prints one
# "command args..." line per invocation; "--format bash" prefixes a
# "#!/usr/bin/env bash" header and each line with "./<script>", so piping the
# output to a file produces a runnable replay script; "--format json" prints a
# JSON array of {name, args, extra} objects. The as-invoked form (the tokens the
# user typed) is rendered by default; "--resolved" renders the resolved form
# instead (defaults, flags, and ENV[...] pinned). "--annotate" adds an id, time,
# and exit status to each entry; "--output <file>" writes to a file instead of
# standard output. The experiment is guaranteed bootstrapped by the framework's
# central guard.
# ------------------------------------------------------------------------------
_knit_history_show() {
    local format resolved annotate out_file
    format="$(knit_get_parameter "format" "$@")"     || format="default"
    resolved="$(knit_get_parameter "resolved" "$@")" || resolved="false"
    annotate="$(knit_get_parameter "annotate" "$@")" || annotate="false"
    out_file="$(knit_get_parameter "output" "$@")"   || out_file=""

    # A database bootstrapped before this feature has no table: an empty history.
    local has_table
    has_table="$(_knit_sqlite3 \
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${_KNIT_HISTORY_TABLE}';")"

    local col="invoked" sql=""
    [[ "${resolved}" == "true" ]] && col="resolved"
    [[ -n "${has_table}" ]] && _knit_history_row_sql sql "${col}" "$@"

    if [[ -n "${out_file}" ]]; then
        _knit_history_emit "${format}" "${annotate}" "${has_table}" "${sql}" > "${out_file}"
    else
        _knit_history_emit "${format}" "${annotate}" "${has_table}" "${sql}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_history_discover()
#
# Lazily register the "history" subcommands the first time any of them is
# reached, listed in "--help", or walked by "describe" (see
# knit_with_subcommand_discovery). The commands read the database and never
# record themselves (knit_without_provenance), so they never appear in their own
# output.
#
# @param[in] parent The parent command's display name (unused).
# ------------------------------------------------------------------------------
_knit_history_discover() {
    knit_register "history:show" _knit_history_show \
        "Show a replayable history of the top-level commands you invoked."
    _knit_is_builtin
    knit_without_provenance
    knit_with_optional "format:history_format" "default" \
        "Output format: default (one line per command), bash (a runnable replay script), or json."
    knit_with_flag "resolved" \
        "Render the resolved form (defaults, flags, and ENV[...] pinned) instead of the tokens as typed."
    knit_with_optional "status:history_status" "success" \
        "Which invocations to show by exit status: success (default), failure, or all."
    knit_with_optional "command:string" "" \
        "Only these commands (comma-separated, colon notation; a ':*' suffix also matches subcommands)."
    knit_with_optional "since:string" "" \
        "Only invocations at or after this point (a UUID or an ISO-8601 timestamp)."
    knit_with_optional "until:string" "" \
        "Only invocations before this point (a UUID or an ISO-8601 timestamp)."
    knit_with_optional "id:string" "" \
        "Only the invocation with this id."
    knit_with_optional "first:integer" "" \
        "Keep only the first N invocations after the other filters apply."
    knit_with_optional "last:integer" "" \
        "Keep only the last N invocations after the other filters apply."
    knit_with_flag "annotate" \
        "Annotate each entry with its id, time, and exit status."
    knit_with_optional "output:string" "" \
        "Write to this file instead of standard output."
    knit_done
}

# ------------------------------------------------------------------------------
# Registration of the history command. The output-format enum is registered
# eagerly (it is resolved when "history:show" declares its --format option); the
# subcommands are registered lazily by _knit_history_discover so sourcing knit.sh
# does not build the subtree up front.
# ------------------------------------------------------------------------------
knit_enum "history_format" "default" "bash" "json"
_knit_is_builtin

knit_enum "history_status" "success" "failure" "all"
_knit_is_builtin

knit_register history knit_empty "Access the history of commands run in this experiment."
_knit_is_builtin
knit_without_provenance
knit_without_history
knit_with_subcommand_discovery _knit_history_discover
knit_done
