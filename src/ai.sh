#!/bin/bash

## @file ai.sh

# ------------------------------------------------------------------------------
# @var _KNIT_AI_DEFAULT_BASE_URL
#
# Literal fallback base URL used when no base-url env var resolves to a value.
# Kept in sync with the same default hard-coded on bootstrap's --ai-base-url
# option (src/boostrap.sh loads before this file, so it cannot reference this
# variable at registration time).
# ------------------------------------------------------------------------------
declare -g _KNIT_AI_DEFAULT_BASE_URL
_KNIT_AI_DEFAULT_BASE_URL="https://api.openai.com/v1"

# ------------------------------------------------------------------------------
# @var _KNIT_AI_TOOL_OUTPUT_MAX_BYTES
#
# Approximate ceiling on the size of a single tool result handed back to the
# model. A tool whose output exceeds this is cut to the budget and marked with an
# explicit "…(truncated)" line, so a huge `describe` or query result can't blow
# the context window silently. Measured in characters (== bytes for ASCII, which
# covers knit's introspection output).
# ------------------------------------------------------------------------------
declare -g _KNIT_AI_TOOL_OUTPUT_MAX_BYTES
_KNIT_AI_TOOL_OUTPUT_MAX_BYTES=8192

# ------------------------------------------------------------------------------
# @fn _knit_ai_store_config()
#
# Write the provider-access configuration to the metadata table as `ai.*`
# key/value pairs, through the same `metadata store` path used elsewhere. This
# is the writer used by bootstrap's `--ai-*` options to store a full config in
# one shot (update mode writes each key on its own).
#
# Only env-var *names* and non-secret defaults are stored; no API key ever
# reaches the database.
#
# @param[in] api_key_env Name of the env var holding the API key.
# @param[in] base_url_env Name of the env var holding the endpoint base URL.
# @param[in] model_env Name of the env var holding the model id.
# @param[in] base_url Literal fallback base URL.
# @param[in] model Literal fallback model id.
# @param[in] overwrite "true" to overwrite existing keys, anything else to fail on
#        a duplicate key.
# ------------------------------------------------------------------------------
_knit_ai_store_config() {
    local api_key_env="$1"
    local base_url_env="$2"
    local model_env="$3"
    local base_url="$4"
    local model="$5"
    local overwrite="$6"

    # Pass the flag in its bare CLI form (--force); the framework converts it to
    # the "--force true" the metadata store body reads.
    local -a force=()
    [[ "${overwrite}" == "true" ]] && force=(--force)

    knit metadata store --key "ai.api_key_env"  --value "${api_key_env}"  "${force[@]}"
    knit metadata store --key "ai.base_url_env" --value "${base_url_env}" "${force[@]}"
    knit metadata store --key "ai.model_env"    --value "${model_env}"    "${force[@]}"
    knit metadata store --key "ai.base_url"     --value "${base_url}"     "${force[@]}"
    knit metadata store --key "ai.model"        --value "${model}"        "${force[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_resolve_config()
#
# Resolve the provider access configuration for an `ai` call. Reads the `ai.*`
# metadata keys, indirect-expands the stored env-var *names* to their values
# (never `eval`), and applies precedence/fallbacks:
#   - api key:  value of the env var named by `ai.api_key_env` (required).
#   - base url: value of the env var named by `ai.base_url_env` if set, else the
#               `ai.base_url` literal, else _KNIT_AI_DEFAULT_BASE_URL.
#   - model:    the model_override argument if non-empty, else the value of the
#               env var named by `ai.model_env`, else the `ai.model` literal.
#
# Fatals (with a hint pointing at `bootstrap --ai-*`) when the provider is
# unconfigured, the API key env var is empty/unset, or no model can be resolved.
# The resolved API key is returned only through the caller-named output variable;
# it is never logged, traced, or echoed.
#
# @param[out] __knit_ret1 Name of the variable to hold the resolved API key.
# @param[out] __knit_ret2 Name of the variable to hold the resolved base URL.
# @param[out] __knit_ret3 Name of the variable to hold the resolved model id.
# @param[in] model_override Optional model id that takes precedence over metadata.
# ------------------------------------------------------------------------------
_knit_ai_resolve_config() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local -n __knit_ret3=$3
    local model_override="${4:-}"

    local api_key_env base_url_env model_env base_url_literal model_literal
    _knit_metadata_get api_key_env    "ai.api_key_env"
    _knit_metadata_get base_url_env   "ai.base_url_env"
    _knit_metadata_get model_env      "ai.model_env"
    _knit_metadata_get base_url_literal "ai.base_url"
    _knit_metadata_get model_literal  "ai.model"

    if [[ -z "${api_key_env}" ]]; then
        knit_fatal "AI provider is not configured. Run \"%s bootstrap --ai-api-key-env <NAME>\" to configure it." \
            "${KNIT_SCRIPT_NAME}"
    fi

    # These working locals are __-prefixed on purpose: known callers pass their
    # output arguments as `api_key` and `base_url`, so a plain local of the same
    # name would shadow the output nameref (`__knit_ret*`) and silently misdirect
    # the write back to this function's own local. See the nameref rules in
    # README/CLAUDE.md.
    local __knit_api_key="${!api_key_env}"
    if [[ -z "${__knit_api_key}" ]]; then
        knit_fatal "AI API key environment variable \$%s is empty or unset." \
            "${api_key_env}"
    fi

    local __knit_base_url=""
    [[ -n "${base_url_env}" ]] && __knit_base_url="${!base_url_env}"
    [[ -z "${__knit_base_url}" ]] && __knit_base_url="${base_url_literal}"
    [[ -z "${__knit_base_url}" ]] && __knit_base_url="${_KNIT_AI_DEFAULT_BASE_URL}"

    local __knit_model="${model_override}"
    [[ -z "${__knit_model}" && -n "${model_env}" ]] && __knit_model="${!model_env}"
    [[ -z "${__knit_model}" ]] && __knit_model="${model_literal}"
    if [[ -z "${__knit_model}" ]]; then
        knit_fatal "No AI model configured. Pass --model, set the model env var, or configure a default with \"%s bootstrap --ai-model <id>\"." \
            "${KNIT_SCRIPT_NAME}"
    fi

    __knit_ret1="${__knit_api_key}"
    __knit_ret2="${__knit_base_url}"
    __knit_ret3="${__knit_model}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_chat_request()
#
# Build an OpenAI chat-completions request from the given model, messages array,
# and optional tools array, POST it to <base_url>/chat/completions, and print the
# raw response JSON on stdout for the caller to parse.
#
# The API key is passed to curl through a mode-600 config file (never a -H flag),
# so it never appears in the process argv (`ps`) or in any trace. Only a redacted
# form of the request is traced. A provider error (`.error` in the response) is
# surfaced through the logging system and turned into a fatal; the request body
# is never dumped.
#
# @param[in] base_url Endpoint base URL (without a trailing /chat/completions).
# @param[in] api_key Resolved API key (kept local; never logged).
# @param[in] model Model id.
# @param[in] messages_json JSON array of chat messages.
# @param[in] tools_json Optional JSON array of tool definitions (omitted when empty).
# ------------------------------------------------------------------------------
_knit_ai_chat_request() {
    local base_url="$1"
    local api_key="$2"
    local model="$3"
    local messages_json="$4"
    local tools_json="${5:-}"

    local body
    # shellcheck disable=SC2016 # $model/$messages/$tools are jq variables, not shell
    if ! body=$(_knit_jq -n \
            --arg model "${model}" \
            --argjson messages "${messages_json}" \
            --argjson tools "${tools_json:-null}" \
            '{model: $model, messages: $messages}
             + (if ($tools == null or $tools == []) then {} else {tools: $tools} end)'); then
        knit_fatal "Failed to build the AI chat request body."
    fi

    local url="${base_url%/}/chat/completions"

    _knit_ensure_trace_file

    # Keep the API key out of the process argv and out of any trace by passing
    # the Authorization header (and the request body) through a curl config file
    # created with restrictive permissions, rather than command-line arguments.
    local cfg body_file
    cfg=$(mktemp "${TMPDIR:-/tmp}/knit.ai.cfg.XXXXXX")
    body_file=$(mktemp "${TMPDIR:-/tmp}/knit.ai.body.XXXXXX")
    printf '%s' "${body}" > "${body_file}"
    {
        printf 'url = "%s"\n'                          "${url}"
        printf 'header = "Authorization: Bearer %s"\n' "${api_key}"
        printf 'header = "Content-Type: application/json"\n'
        printf 'data-binary = "@%s"\n'                 "${body_file}"
    } > "${cfg}"

    knit_trace "AI request: POST %s (model=%s, Authorization: Bearer <redacted>)" \
        "${url}" "${model}"

    # Capture the response body and HTTP status separately so an HTTP-level
    # failure can be reported with the server's body inline instead of being
    # swallowed and surfacing later as a confusing "no message" error.
    local resp_file http_code
    resp_file=$(mktemp "${TMPDIR:-/tmp}/knit.ai.resp.XXXXXX")
    http_code=$(curl -s -S -K "${cfg}" -o "${resp_file}" -w '%{http_code}' \
        2>>"${_KNIT_TRACE_FILE}")
    local curl_status=$?
    local resp
    resp=$(cat "${resp_file}")
    rm -f "${cfg}" "${body_file}" "${resp_file}"

    if (( curl_status != 0 )); then
        knit_fatal "AI request to %s failed (curl exit %d). See %s." \
            "${url}" "${curl_status}" "${_KNIT_TRACE_FILE}"
    fi

    # A structured provider error gets its own message regardless of status code.
    local err
    err=$(printf '%s' "${resp}" | _knit_jq -r '.error.message // empty' 2>/dev/null)
    if [[ -n "${err}" ]]; then
        local etype
        etype=$(printf '%s' "${resp}" | _knit_jq -r '.error.type // "error"' 2>/dev/null)
        knit_fatal "AI provider error (%s): %s" "${etype}" "${err}"
    fi

    # Any other non-2xx status (e.g. a 404 from a wrong base URL, whose body is
    # not an OpenAI error object) is reported with the raw body so the cause is
    # visible without digging through the trace file.
    if [[ ! "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
        knit_fatal "AI request to %s returned HTTP %s. Response: %s" \
            "${url}" "${http_code}" "${resp:0:500}"
    fi

    printf '%s\n' "${resp}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_sql_is_readonly()
#
# Shared read-only SQL guard for the `knit_db_query` tool and (in a later
# milestone) `ai query`. A statement is considered read-only when its leading
# keyword is one of SELECT / WITH / EXPLAIN / PRAGMA and it contains no write
# keyword (INSERT / UPDATE / DELETE / DROP / ALTER / CREATE / REPLACE / ATTACH)
# as a whole word anywhere. The second check catches piggy-backed writes such as
# "SELECT 1; DROP TABLE runs" that pass the leading-keyword test.
#
# Word boundaries are handled by uppercasing the statement and replacing every
# non-word character with a space, then matching the space-padded keyword; this
# avoids relying on the non-POSIX `\b` regex escape and never misfires on a
# column named e.g. `created_at` (the underscore keeps it one token).
#
# @param[in] sql The SQL statement to check.
# @return 0 if the statement is read-only, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_ai_sql_is_readonly() {
    local up="${1^^}"

    # Strip leading whitespace, then require an allowed leading keyword followed
    # by a non-word character or end-of-string (so "SELECTED" is not "SELECT").
    local trimmed="${up#"${up%%[![:space:]]*}"}"
    [[ "${trimmed}" =~ ^(SELECT|WITH|EXPLAIN|PRAGMA)([^A-Z0-9_]|$) ]] || return 1

    # Reject any write keyword appearing as a whole word anywhere.
    local norm=" ${up//[^A-Z0-9_]/ } "
    local kw
    for kw in INSERT UPDATE DELETE DROP ALTER CREATE REPLACE ATTACH; do
        [[ "${norm}" == *" ${kw} "* ]] && return 1
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_truncate()
#
# Print the given text, cut to _KNIT_AI_TOOL_OUTPUT_MAX_BYTES with an explicit
# "…(truncated)" marker appended when it is longer. Used to bound every tool
# result handed back to the model.
#
# @param[in] text The text to bound.
# ------------------------------------------------------------------------------
_knit_ai_truncate() {
    local text="$1"
    local max="${_KNIT_AI_TOOL_OUTPUT_MAX_BYTES}"
    if (( ${#text} > max )); then
        printf '%s\n…(truncated)\n' "${text:0:max}"
    else
        printf '%s\n' "${text}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_tool_describe()
#
# Tool handler: structured introspection of the command tree, as YAML. Optional
# `only` (comma-separated command list) and `recursive` narrow/expand the scope.
#
# @param[in] only Optional comma-separated command list (colon form, e.g. "a,b:c").
# @param[in] recursive "true" to also include the selected commands' subcommands.
# ------------------------------------------------------------------------------
_knit_ai_tool_describe() {
    local only="${1:-}"
    local recursive="${2:-}"
    local -a args=(describe --format yaml)
    [[ -n "${only}" ]] && args+=(--only "${only}")
    [[ "${recursive}" == "true" ]] && args+=(--recursive)
    knit "${args[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_tool_help()
#
# Tool handler: the `--help` text for one specific command. The command name may
# contain spaces for a nested command (e.g. "job show stdout"); it is split into
# words before being passed to knit.
#
# @param[in] command The command whose help to show (space-separated for nesting).
# ------------------------------------------------------------------------------
_knit_ai_tool_help() {
    local command="$1"
    if [[ -z "${command}" ]]; then
        printf 'Error: knit_help requires a "command" argument.\n'
        return 0
    fi
    local -a parts=()
    read -r -a parts <<< "${command}"
    knit "${parts[@]}" --help
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_tool_metadata_show()
#
# Tool handler: all experiment metadata. Everything in the metadata table is safe
# to send (only env-var names and non-secret config, never secrets).
# ------------------------------------------------------------------------------
_knit_ai_tool_metadata_show() {
    knit metadata show
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_tool_db_query()
#
# Tool handler: run a read-only SQL query against the experiment database and
# print the result (aligned columns with a header). The statement must pass
# _knit_ai_sql_is_readonly; a rejected statement returns an error string (fed
# back to the model) rather than being run. The query always runs on the read
# path (_knit_sqlite3, never _knit_sqlite3_write), so it can never mutate the DB.
#
# @param[in] sql The SQL statement to run.
# ------------------------------------------------------------------------------
_knit_ai_tool_db_query() {
    local sql="$1"
    if [[ -z "${sql}" ]]; then
        printf 'Error: knit_db_query requires a "sql" argument.\n'
        return 0
    fi
    if ! _knit_ai_sql_is_readonly "${sql}"; then
        printf 'Error: query rejected. Only read-only statements are allowed (leading SELECT/WITH/EXPLAIN/PRAGMA, no write keywords).\n'
        return 0
    fi
    _knit_sqlite3 -header -column "${sql}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_tool_job_output()
#
# Tool handler: a recorded job's captured stdout/stderr or its generated batch
# script, via the `job show <stream>` subcommands (there is no top-level `knit
# stdout` command).
#
# @param[in] id The job UUID.
# @param[in] stream One of "stdout" (default), "stderr", or "script".
# ------------------------------------------------------------------------------
_knit_ai_tool_job_output() {
    local id="$1"
    local stream="${2:-stdout}"
    if [[ -z "${id}" ]]; then
        printf 'Error: knit_job_output requires an "id" argument.\n'
        return 0
    fi
    case "${stream}" in
        stdout|stderr|script) ;;
        *)
            printf 'Error: unknown stream "%s" (use stdout, stderr, or script).\n' \
                "${stream}"
            return 0
            ;;
    esac
    knit job show "${stream}" --id "${id}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_tools_schema()
#
# Print the OpenAI `tools[]` JSON array describing the read-only tool set exposed
# to the model. There is deliberately no command-execution tool: the model can
# inspect the experiment but cannot run experiment commands or mutate anything.
# ------------------------------------------------------------------------------
_knit_ai_tools_schema() {
    _knit_jq -n '
    [
      { "type": "function", "function": {
          "name": "knit_describe",
          "description": "Structured introspection of the experiment: its commands, parameters, types and outputs, as YAML. Prefer this before answering structural questions.",
          "parameters": { "type": "object", "properties": {
              "only": { "type": "string", "description": "Optional comma-separated command list (colon form, e.g. \"a,b:c\") to restrict the description to." },
              "recursive": { "type": "boolean", "description": "With only, also include the selected commands subcommands." }
          }, "required": [] } } },
      { "type": "function", "function": {
          "name": "knit_help",
          "description": "The --help text for one specific command.",
          "parameters": { "type": "object", "properties": {
              "command": { "type": "string", "description": "The command whose help to show; space-separated for a nested command, e.g. \"job show stdout\"." }
          }, "required": ["command"] } } },
      { "type": "function", "function": {
          "name": "knit_metadata_show",
          "description": "Show all stored experiment metadata (key/value pairs). Safe: contains only env-var names and non-secret config.",
          "parameters": { "type": "object", "properties": {}, "required": [] } } },
      { "type": "function", "function": {
          "name": "knit_db_query",
          "description": "Run a read-only SQL query against the experiment database to inspect recorded runs, jobs and outputs. Only SELECT/WITH/EXPLAIN/PRAGMA statements are allowed.",
          "parameters": { "type": "object", "properties": {
              "sql": { "type": "string", "description": "A single read-only SQL statement." }
          }, "required": ["sql"] } } },
      { "type": "function", "function": {
          "name": "knit_job_output",
          "description": "Retrieve a recorded jobs captured stdout, stderr, or its generated batch script.",
          "parameters": { "type": "object", "properties": {
              "id": { "type": "string", "description": "The job UUID." },
              "stream": { "type": "string", "enum": ["stdout", "stderr", "script"], "description": "Which output to retrieve (default stdout)." }
          }, "required": ["id"] } } }
    ]'
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_dispatch_tool()
#
# Route a model-requested tool call to its handler and print the (truncated)
# result. Tool arguments arrive as a JSON object string and are parsed with
# _knit_jq -r. Only allowlisted tools run; an unknown name yields an error
# string. Handler output (including any fatal from the underlying knit surface,
# e.g. an unknown job id) is captured so it becomes the tool result rather than
# aborting the agentic loop.
#
# Before running the handler, the recording-suppression state is cleared (unset
# KNIT_DISABLE_RECORDING, reset _KNIT_RECORDING_SUPPRESSED) so a recordable
# tool-command would record exactly as if the user had run it directly. The `ai`
# command's own non-recording state never leaks into the commands it drives.
#
# @param[in] name The tool name (e.g. "knit_describe").
# @param[in] args_json JSON object string of the tool's arguments.
# ------------------------------------------------------------------------------
_knit_ai_dispatch_tool() {
    local name="$1"
    local args_json="$2"
    [[ -z "${args_json}" ]] && args_json="{}"

    # Clear recording suppression for the tool invocation (see above).
    unset KNIT_DISABLE_RECORDING
    _KNIT_RECORDING_SUPPRESSED=""

    local out
    case "${name}" in
        knit_describe)
            local only recursive
            only=$(printf '%s' "${args_json}" | _knit_jq -r '.only // ""')
            recursive=$(printf '%s' "${args_json}" | _knit_jq -r '.recursive // false')
            out=$(_knit_ai_tool_describe "${only}" "${recursive}" 2>&1)
            ;;
        knit_help)
            local command
            command=$(printf '%s' "${args_json}" | _knit_jq -r '.command // ""')
            out=$(_knit_ai_tool_help "${command}" 2>&1)
            ;;
        knit_metadata_show)
            out=$(_knit_ai_tool_metadata_show 2>&1)
            ;;
        knit_db_query)
            local sql
            sql=$(printf '%s' "${args_json}" | _knit_jq -r '.sql // ""')
            out=$(_knit_ai_tool_db_query "${sql}" 2>&1)
            ;;
        knit_job_output)
            local id stream
            id=$(printf '%s' "${args_json}" | _knit_jq -r '.id // ""')
            stream=$(printf '%s' "${args_json}" | _knit_jq -r '.stream // "stdout"')
            out=$(_knit_ai_tool_job_output "${id}" "${stream}" 2>&1)
            ;;
        *)
            out="Error: unknown tool \"${name}\"."
            ;;
    esac

    _knit_ai_truncate "${out}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_describe_summary()
#
# Print a compact one-line-per-command summary of the whole command tree
# ("- <full command path>: <description>"), used to seed the model's first turn
# so it need not call knit_describe just to learn what commands exist. Built from
# the machine-readable `describe --format json --compact` output. Best-effort: a
# failure prints nothing (the model can still call the tools for detail).
# ------------------------------------------------------------------------------
_knit_ai_describe_summary() {
    local json
    json=$(knit describe --format json --compact 2>/dev/null) || return 0
    printf '%s' "${json}" | _knit_jq -r '
        def walk: .[]? | "- \(.path | join(" ")): \(.description // "")",
                         (.subcommands | walk);
        .commands | walk' 2>/dev/null
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_default_system_prompt()
#
# Print the default system prompt for `ai ask`: a short explanation of knit, the
# instruction to answer about *this* experiment using only the read-only tools,
# and a compact seeded summary of the available commands. Overridden wholesale by
# `ai ask --system`.
# ------------------------------------------------------------------------------
_knit_ai_default_system_prompt() {
    local summary
    summary=$(_knit_ai_describe_summary)
    cat <<EOF
You are an assistant embedded in "knit", a Bash framework for reproducible HPC
experiments. Answer questions about THIS specific experiment (invoked as
"${KNIT_SCRIPT_NAME}") by inspecting it with the read-only tools provided. Never
invent commands, parameters, or results; if you are unsure, call a tool.

Prefer calling knit_describe (optionally with "only") before answering questions
about commands, parameters, or outputs. Use knit_db_query to inspect recorded
runs and jobs, knit_job_output to read a job's captured stdout/stderr or batch
script, and knit_metadata_show for configuration. All tools are read-only: you
cannot run experiment commands or modify anything.

When answering, use ASD-STE100.

The experiment exposes these commands:
${summary}
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_loop()
#
# Run the agentic tool-calling loop for `ai ask`. Seeds the conversation with the
# system prompt and the user question, then repeatedly POSTs the accumulating
# message array (with the read-only tool schema) to the provider. On each turn:
# the assistant message is appended; if it carries no tool calls it is the final
# answer (printed and the loop returns); otherwise every requested tool is
# dispatched and its result appended as a tool-role message before the next turn.
# The message array is grown with `_knit_jq --argjson` so JSON types stay intact.
#
# Stops after max_iterations rounds with a warning if no final answer is reached.
#
# @param[in] base_url Resolved endpoint base URL.
# @param[in] api_key Resolved API key (passed straight to the request helper).
# @param[in] model Resolved model id.
# @param[in] question The user's natural-language question.
# @param[in] system_prompt The system prompt to seed the conversation with.
# @param[in] max_iterations Hard cap on tool-call rounds.
# @param[in] raw "true" to print the raw final message JSON instead of its text.
# @param[in] verbose "true" to stream each tool call and result to stderr.
# @return 0 when a final answer is produced, 1 on hitting the iteration cap.
# ------------------------------------------------------------------------------
_knit_ai_loop() {
    local base_url="$1"
    local api_key="$2"
    local model="$3"
    local question="$4"
    local system_prompt="$5"
    local max_iterations="$6"
    local raw="$7"
    local verbose="$8"

    local tools
    tools=$(_knit_ai_tools_schema)

    local messages
    # shellcheck disable=SC2016 # $system/$question are jq variables, not shell
    messages=$(_knit_jq -n \
        --arg system "${system_prompt}" \
        --arg question "${question}" \
        '[{role: "system", content: $system}, {role: "user", content: $question}]')

    local i resp message n_tools
    local j tc_id tc_name tc_args result
    for (( i = 1; i <= max_iterations; i++ )); do
        resp=$(_knit_ai_chat_request "${base_url}" "${api_key}" "${model}" \
            "${messages}" "${tools}") || return 1

        message=$(printf '%s' "${resp}" | _knit_jq -c '.choices[0].message')
        if [[ -z "${message}" || "${message}" == "null" ]]; then
            knit_fatal "AI response contained no message. Response: %s" \
                "${resp:0:500}"
        fi

        # Append the assistant message (keeps any tool_calls intact for the
        # follow-up tool-role messages the API requires).
        # shellcheck disable=SC2016 # $m/$msg are jq variables, not shell
        messages=$(_knit_jq -n \
            --argjson m "${messages}" \
            --argjson msg "${message}" \
            '$m + [$msg]')

        n_tools=$(printf '%s' "${message}" | _knit_jq -r '(.tool_calls // []) | length')
        if (( n_tools == 0 )); then
            if [[ "${raw}" == "true" ]]; then
                printf '%s\n' "${message}"
            else
                printf '%s' "${message}" | _knit_jq -r '.content // ""'
            fi
            return 0
        fi

        for (( j = 0; j < n_tools; j++ )); do
            tc_id=$(printf '%s' "${message}" | _knit_jq -r ".tool_calls[${j}].id")
            tc_name=$(printf '%s' "${message}" | _knit_jq -r ".tool_calls[${j}].function.name")
            tc_args=$(printf '%s' "${message}" | _knit_jq -r ".tool_calls[${j}].function.arguments")

            [[ "${verbose}" == "true" ]] && \
                printf 'ai: tool call %s(%s)\n' "${tc_name}" "${tc_args}" >&2

            result=$(_knit_ai_dispatch_tool "${tc_name}" "${tc_args}")

            [[ "${verbose}" == "true" ]] && \
                printf 'ai: tool result for %s:\n%s\n' "${tc_name}" "${result}" >&2

            # Append the tool result as a tool-role message keyed by call id.
            # shellcheck disable=SC2016 # $m/$id/$content are jq variables, not shell
            messages=$(_knit_jq -n \
                --argjson m "${messages}" \
                --arg id "${tc_id}" \
                --arg content "${result}" \
                '$m + [{role: "tool", tool_call_id: $id, content: $content}]')
        done
    done

    knit_warning "ai: hit --max-iterations (%s) without a final answer." \
        "${max_iterations}"
    return 1
}

# ------------------------------------------------------------------------------
# Registration of the ai command group.
#
# `ai` commands read/write the metadata table and/or the run/job database, so
# they are NOT usable before bootstrap: the central runtime guard refuses them
# uniformly until the experiment is bootstrapped.
# ------------------------------------------------------------------------------
knit_register ai knit_empty "Talk to your experiment in natural language."
_knit_is_builtin
knit_without_provenance
knit_done

# ------------------------------------------------------------------------------
# Registration of 'ai ask'.
# ------------------------------------------------------------------------------
knit_register "ai:ask" _knit_ai_ask \
    "Ask a natural-language question about the experiment."
_knit_is_builtin
knit_without_provenance
knit_with_required "question:string" \
    "The natural-language question to answer."
knit_with_optional "model:string" "" \
    "Override the configured model for this call."
knit_with_optional "max-iterations:integer" "8" \
    "Hard cap on agentic tool-call rounds."
knit_with_optional "system:string" "" \
    "Replace the built-in system prompt with this text."
knit_with_flag "raw" \
    "Print the raw final message JSON instead of just the answer text."
knit_with_flag "verbose" \
    "Stream each tool call and tool result to stderr as the loop runs."
# ------------------------------------------------------------------------------
# @fn _knit_ai_ask()
#
# Body of 'ai ask': resolve the provider config, build the system prompt (the
# built-in one unless --system overrides it), and run the agentic loop, which
# prints the final answer. The resolved API key stays in a local and is never
# logged or recorded.
# ------------------------------------------------------------------------------
_knit_ai_ask() {
    local question model max_iterations system raw verbose
    question="$(knit_get_parameter "question" "$@")"
    model="$(knit_get_parameter "model" "$@")"
    max_iterations="$(knit_get_parameter "max-iterations" "$@")"
    system="$(knit_get_parameter "system" "$@")"
    raw="$(knit_get_parameter "raw" "$@")" || raw="false"
    verbose="$(knit_get_parameter "verbose" "$@")" || verbose="false"

    local api_key base_url resolved_model
    _knit_ai_resolve_config api_key base_url resolved_model "${model}"

    local system_prompt="${system}"
    [[ -z "${system_prompt}" ]] && system_prompt="$(_knit_ai_default_system_prompt)"

    _knit_ai_loop "${base_url}" "${api_key}" "${resolved_model}" \
        "${question}" "${system_prompt}" "${max_iterations}" "${raw}" "${verbose}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_ai_query_mode_args()
#
# Translate an `ai query --format` value (a `query_format` enum value) plus the
# `--no-header`/`--separator` options into the sequence of sqlite3 `-cmd ".mode
# …"` arguments that select the requested output mode, filled into the caller's
# array by nameref. The enum values map 1:1 onto sqlite3 `.mode` names, so no
# lookup table is needed. Headers are on by default (`.headers on`) and turned
# off by `--no-header`; a non-empty separator overrides the mode default.
#
# @param[out] __knit_ret Name of the array variable to fill with the sqlite3 args.
# @param[in] format The query_format enum value (e.g. "box", "csv").
# @param[in] no_header "true" to omit column headers.
# @param[in] separator Optional column separator for csv/list modes.
# ------------------------------------------------------------------------------
_knit_ai_query_mode_args() {
    local -n __knit_ret=$1
    local format="$2"
    local no_header="$3"
    local separator="$4"

    __knit_ret=(-cmd ".mode ${format}")
    if [[ "${no_header}" == "true" ]]; then
        __knit_ret+=(-cmd ".headers off")
    else
        __knit_ret+=(-cmd ".headers on")
    fi
    [[ -n "${separator}" ]] && __knit_ret+=(-cmd ".separator ${separator}")
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_extract_query()
#
# Extract the bare query and its language from a model reply, tolerating a reply
# wrapped in a Markdown code fence (```sql … ``` / ```cypher … ```) and
# surrounding whitespace even though the system prompt asks for none. When a
# fence is present, the content between the first and next fence is taken; the
# fence info string (first line) is read as the language, case-insensitively
# (`sql`/`cypher`), and dropped. When the info string is missing or unknown, the
# language is inferred from the leading keyword: MATCH/OPTIONAL/UNWIND/CALL ⇒
# cypher, SELECT/WITH/EXPLAIN/PRAGMA ⇒ sql, anything else ⇒ sql. Leading and
# trailing whitespace is trimmed from the query.
#
# @param[out] lang_out (nameref) receives the detected language ("sql" or "cypher").
# @param[out] query_out (nameref) receives the trimmed query text.
# @param[in] text The raw model reply.
# ------------------------------------------------------------------------------
_knit_ai_extract_query() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    shift 2
    local __query="$1"
    local __lang=""
    local fence='```'
    if [[ "${__query}" == *"${fence}"* ]]; then
        __query="${__query#*"${fence}"}"
        __query="${__query%%"${fence}"*}"
        if [[ "${__query}" == *$'\n'* ]]; then
            local __info="${__query%%$'\n'*}"
            __info="${__info#"${__info%%[![:space:]]*}"}"
            __info="${__info%"${__info##*[![:space:]]}"}"
            case "${__info,,}" in
                sql)    __lang="sql" ;;
                cypher) __lang="cypher" ;;
            esac
            __query="${__query#*$'\n'}"
        fi
    fi
    __query="${__query#"${__query%%[![:space:]]*}"}"
    __query="${__query%"${__query##*[![:space:]]}"}"
    if [[ -z "${__lang}" ]]; then
        local __first="${__query%%[[:space:]]*}"
        case "${__first^^}" in
            MATCH|OPTIONAL|UNWIND|CALL) __lang="cypher" ;;
            SELECT|WITH|EXPLAIN|PRAGMA) __lang="sql" ;;
            *)                          __lang="sql" ;;
        esac
    fi
    __knit_ret1="${__lang}"
    __knit_ret2="${__query}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_query_system_prompt()
#
# Print the system prompt for `ai query`. It instructs the model to translate the
# question into exactly ONE read-only query wrapped in a single language-tagged
# fenced block, and seeds it from live state: the SQLite schema
# (`_knit_sqlite3 ".schema"`), the knit-graph node-label map
# (`_knit_query_build_names`), the provenance edge model, and a compact
# `describe` summary for column and edge semantics.
#
# The SQL and Cypher halves are gated by the pinned language: with `sql` or
# `cypher` only that half (and the matching reply contract) is emitted so the
# model isn't tempted to use the other backend; with `auto` (the default) both
# halves and the when-to-prefer-each guidance are emitted and the model chooses.
#
# @param[in] lang Pinned language ("auto"/"sql"/"cypher"); defaults to "auto".
# ------------------------------------------------------------------------------
_knit_ai_query_system_prompt() {
    local lang="${1:-auto}"
    local schema summary names_spec
    schema=$(_knit_sqlite3 ".schema" 2>/dev/null)
    summary=$(_knit_ai_describe_summary)
    _knit_query_build_names names_spec

    # Reply contract: narrowed to the pinned language, or the choose-one form.
    local intro
    if [[ "${lang}" == "sql" ]]; then
        intro="You translate a natural-language question about the \"knit\" experiment
\"${KNIT_SCRIPT_NAME}\" into exactly ONE read-only SQL query for its SQLite
database.

Reply with a SINGLE fenced code block tagged \`sql\` and NOTHING else (no prose,
no explanation), for example:
\`\`\`sql
SELECT app, avg(procs) FROM runs GROUP BY app
\`\`\`"
    elif [[ "${lang}" == "cypher" ]]; then
        intro="You translate a natural-language question about the \"knit\" experiment
\"${KNIT_SCRIPT_NAME}\" into exactly ONE read-only Cypher query for its
provenance graph (run by the knit-graph engine).

Reply with a SINGLE fenced code block tagged \`cypher\` and NOTHING else (no
prose, no explanation), for example:
\`\`\`cypher
MATCH (j:submit)-[:call]->(r:runs) RETURN j.job, r.app
\`\`\`"
    else
        intro="You translate a natural-language question about the \"knit\" experiment
\"${KNIT_SCRIPT_NAME}\" into exactly ONE read-only query, choosing the language
that fits best: SQL (run against its SQLite database) or Cypher (run against its
provenance graph by the knit-graph engine).

Reply with a SINGLE fenced code block whose info string is the language --
\`sql\` or \`cypher\` -- and NOTHING else (no prose, no explanation), for
example:
\`\`\`sql
SELECT app, avg(procs) FROM runs GROUP BY app
\`\`\`
or
\`\`\`cypher
MATCH (j:submit)-[:call]->(r:runs) RETURN j.job, r.app
\`\`\`

When to prefer each:
- SQL for filtering, aggregation, and sorting within one table (averages,
  counts, \"the 5 longest runs\", column projections).
- Cypher for relationships and provenance across commands: which command called
  which (\`call\` edges), which setup a job used (\`used_by\` edges), and queries
  filtered by a \`knit_as\` alias on an edge."
    fi

    local sql_half=""
    if [[ "${lang}" != "cypher" ]]; then
        sql_half="SQL rules:
- The statement must be read-only: it must start with SELECT, WITH, EXPLAIN, or
  PRAGMA. Never emit INSERT/UPDATE/DELETE/DROP/ALTER/CREATE/REPLACE/ATTACH.
- Use only the tables and columns present in the schema below.

Database schema:
${schema}"
    fi

    local cypher_half=""
    if [[ "${lang}" != "sql" ]]; then
        cypher_half="Cypher rules (knit-graph subset):
- Read-only only: MATCH, OPTIONAL MATCH, WHERE, RETURN (with DISTINCT,
  aggregation, ORDER BY, LIMIT). Never emit a write clause.
- A node label is a command or table name from the map below; the two sides of
  each map entry are interchangeable (e.g. \`submit\` and \`jobs\` name the same
  nodes). A label's columns are that table's columns in the schema.
  Backtick-quote a label containing a colon, e.g. (s:\`setup:libs\`).
- Edges are directed source-->target, the source being the antecedent:
  \`call\` (a command invoked another; carries start_time/end_time and an
  optional \`alias\` naming the call site) and \`used_by\` (a setup was consumed
  by a later command). Match an alias inline for a single hop, e.g.
  -[{alias:'fast'}]-> or -[e]->() WHERE e.alias = 'fast'.

Cypher authoring rules (avoid these footguns):
- A bare (submit) is a VARIABLE, not a label -- always write (v:label), e.g.
  (j:submit).
- To match an endpoint by name only (e.g. a used_by source whose id is a
  submission uuid, not a body-table row), label the node but do NOT project its
  columns -- projecting forces an id JOIN that fails.
- When a shared node is named differently across two edges, query the two edges
  separately rather than chaining them in one pattern.

Node label map (table=command, either side usable as a label):
${names_spec}"
    fi

    local prompt="${intro}"
    [[ -n "${sql_half}" ]] && prompt+="

${sql_half}"
    [[ -n "${cypher_half}" ]] && prompt+="

${cypher_half}"
    prompt+="

Command reference (for column and edge semantics):
${summary}"
    printf '%s\n' "${prompt}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ai_query_loop()
#
# Run the bounded self-correcting loop behind `ai query`. Seeds the conversation
# with the query system prompt and the user question, then per round: asks the
# model for a single statement, extracts it with its language, and (unless
# --query-only) routes it to the matching read-only backend. SQL is guarded with
# the shared read-only check and run on the read path (_knit_sqlite3, never
# _knit_sqlite3_write); Cypher is run through knit-graph (_knit_knit_graph) with
# the live name<->table map and the same output flags, and needs no separate
# guard because knit-graph rejects write clauses itself. On success the formatted
# result is printed and the loop returns 0. A guard rejection or a backend error
# is fed back to the model as a follow-up message so the next round can correct
# it (including switching language). After max_iterations failed rounds the loop
# fatals, showing the last query and error.
#
# A pinned language (lang != "auto") overrides the per-statement detection so the
# query is always routed to that backend.
#
# With --query-only the first generated statement and its detected language are
# printed (the query on stdout, the language on stderr) and the loop returns
# without touching either backend.
#
# @param[in] base_url Resolved endpoint base URL.
# @param[in] api_key Resolved API key (passed straight to the request helper).
# @param[in] model Resolved model id.
# @param[in] question The user's natural-language question.
# @param[in] system_prompt The system prompt to seed the conversation with.
# @param[in] max_iterations Cap on generate→run→fix rounds.
# @param[in] verbose "true" to stream the chosen language, each generated query, and
#                any backend error to stderr.
# @param[in] query_only "true" to print the generated query and its language and
#                   return without running either backend.
# @param[in] format The query_format enum value for the output mode.
# @param[in] no_header "true" to omit column headers.
# @param[in] separator Optional column separator for csv/list modes.
# @param[in] lang Pinned language ("auto"/"sql"/"cypher"); "auto" defers to the
#             per-statement detection, sql/cypher override it.
# @return 0 on a successful (or --query-only) run; fatals on hitting the cap.
# ------------------------------------------------------------------------------
_knit_ai_query_loop() {
    local base_url="$1"
    local api_key="$2"
    local model="$3"
    local question="$4"
    local system_prompt="$5"
    local max_iterations="$6"
    local verbose="$7"
    local query_only="$8"
    local format="$9"
    local no_header="${10}"
    local separator="${11}"
    local lang_pinned="${12}"

    local messages
    # shellcheck disable=SC2016 # $system/$question are jq variables, not shell
    messages=$(_knit_jq -n \
        --arg system "${system_prompt}" \
        --arg question "${question}" \
        '[{role: "system", content: $system}, {role: "user", content: $question}]')

    local -a mode_args=()
    _knit_ai_query_mode_args mode_args "${format}" "${no_header}" "${separator}"

    # Cypher backend prep (loop-invariant; built once). knit-graph takes the
    # header on/off as the inverse of --no-header, and the live name<->table map
    # lets a node label be written as either a table name or its command name.
    local header="true"
    [[ "${no_header}" == "true" ]] && header="false"
    local -a graph_flags=()
    _knit_query_graph_output_flags graph_flags "${format}" "${header}" "${separator}"
    local names_spec
    _knit_query_build_names names_spec

    local i resp message sql out lang
    local last_sql="" last_err=""
    for (( i = 1; i <= max_iterations; i++ )); do
        resp=$(_knit_ai_chat_request "${base_url}" "${api_key}" "${model}" \
            "${messages}") || return 1

        message=$(printf '%s' "${resp}" | _knit_jq -c '.choices[0].message')
        if [[ -z "${message}" || "${message}" == "null" ]]; then
            knit_fatal "AI response contained no message. Response: %s" \
                "${resp:0:500}"
        fi

        # shellcheck disable=SC2016 # $m/$msg are jq variables, not shell
        messages=$(_knit_jq -n \
            --argjson m "${messages}" \
            --argjson msg "${message}" \
            '$m + [$msg]')

        sql=$(printf '%s' "${message}" | _knit_jq -r '.content // ""')
        _knit_ai_extract_query lang sql "${sql}"
        # A pinned --lang (anything but "auto") overrides per-statement detection.
        [[ "${lang_pinned}" != "auto" ]] && lang="${lang_pinned}"
        last_sql="${sql}"

        if [[ "${verbose}" == "true" ]]; then
            printf 'ai: language: %s\n' "${lang}" >&2
            printf 'ai: generated query:\n%s\n' "${sql}" >&2
        fi

        if [[ "${query_only}" == "true" ]]; then
            [[ "${verbose}" != "true" ]] && printf 'ai: language: %s\n' "${lang}" >&2
            printf '%s\n' "${sql}"
            return 0
        fi

        # Cypher path: route through knit-graph with the name map and output
        # flags. knit-graph itself rejects write clauses (non-zero exit), so no
        # separate read-only guard is needed; a failing round feeds knit-graph's
        # error back to the model, exactly like the SQL branch below.
        if [[ "${lang}" == "cypher" ]]; then
            local -a kg_args=()
            [[ -n "${names_spec}" ]] && kg_args+=(--names "${names_spec}")
            kg_args+=("${graph_flags[@]}")
            kg_args+=("${_KNIT_DATABASE}" "${sql}")
            if out=$(_knit_knit_graph "${kg_args[@]}" 2>&1); then
                printf '%s\n' "${out}"
                return 0
            fi
            last_err="${out}"
            [[ "${verbose}" == "true" ]] && \
                printf 'ai: knit-graph error:\n%s\n' "${last_err}" >&2
            # shellcheck disable=SC2016 # $m/$e are jq variables, not shell
            messages=$(_knit_jq -n \
                --argjson m "${messages}" \
                --arg e "${last_err}" \
                '$m + [{role: "user", content: ("Running that Cypher query failed with this error:\n" + $e + "\nReturn a corrected single read-only query only.")}]')
            continue
        fi

        if ! _knit_ai_sql_is_readonly "${sql}"; then
            last_err="query rejected: only read-only statements are allowed (leading SELECT/WITH/EXPLAIN/PRAGMA, no write keywords)."
            [[ "${verbose}" == "true" ]] && printf 'ai: %s\n' "${last_err}" >&2
            # shellcheck disable=SC2016 # $m/$e are jq variables, not shell
            messages=$(_knit_jq -n \
                --argjson m "${messages}" \
                --arg e "${last_err}" \
                '$m + [{role: "user", content: ("That SQL was rejected: " + $e + " Return a single read-only statement only.")}]')
            continue
        fi

        if out=$(_knit_sqlite3 "${mode_args[@]}" "${sql}" 2>&1); then
            printf '%s\n' "${out}"
            return 0
        fi
        last_err="${out}"
        [[ "${verbose}" == "true" ]] && \
            printf 'ai: sqlite error:\n%s\n' "${last_err}" >&2
        # shellcheck disable=SC2016 # $m/$e are jq variables, not shell
        messages=$(_knit_jq -n \
            --argjson m "${messages}" \
            --arg e "${last_err}" \
            '$m + [{role: "user", content: ("Running that SQL failed with this sqlite error:\n" + $e + "\nReturn a corrected single read-only SQL statement only.")}]')
    done

    knit_fatal "ai query: could not produce a working query after %s attempts. Last SQL: %s ; last error: %s" \
        "${max_iterations}" "${last_sql}" "${last_err}"
}

# ------------------------------------------------------------------------------
# Registration of the query_format enum shared by 'ai query', 'query graph', and
# 'query sql'.
#
# The values are the output modes both backends understand (knit-graph's
# `-<mode>` flags and sqlite3's `.mode` names); `box` is the human-facing default
# for 'ai query' while 'query' defaults to `list`. It is defined here, the
# earliest-loading file that uses it, so the `format:query_format` parameter
# declarations in this file and in src/query.sh both resolve the type at
# registration time.
# ------------------------------------------------------------------------------
knit_enum "query_format" \
    "list" "json" "box" "csv" "markdown" "table" "line" "html" \
    "ascii" "column" "tabs"
_knit_is_builtin

# ------------------------------------------------------------------------------
# Registration of the query-language enum for 'ai query --lang'.
#
# `auto` lets the loop detect the language of each generated statement; `sql` and
# `cypher` pin generation to one language and override detection.
# ------------------------------------------------------------------------------
knit_enum "ai_query_lang" "auto" "sql" "cypher"
_knit_is_builtin

# ------------------------------------------------------------------------------
# Registration of 'ai query'.
# ------------------------------------------------------------------------------
knit_register "ai:query" _knit_ai_query \
    "Answer a question by generating and running one read-only SQL or Cypher query."
_knit_is_builtin
knit_without_provenance
knit_with_required "question:string" \
    "The natural-language question to answer."
knit_with_optional "lang:ai_query_lang" "auto" \
    "Query language: auto (detect), sql, or cypher."
knit_with_optional "format:query_format" "box" \
    "Output mode: box, column, csv, json, line, list, markdown, table, html, ascii, tabs."
knit_with_flag "no-header" \
    "Omit column headers (tabular/CSV modes)."
knit_with_optional "separator:string" "" \
    "Column separator for csv/list modes (defaults to the sqlite default)."
knit_with_optional "max-iterations:integer" "3" \
    "Cap on generate -> run -> fix rounds."
knit_with_optional "model:string" "" \
    "Override the configured model for this call."
knit_with_flag "query-only" \
    "Print the generated query and its language without running it."
knit_with_flag "verbose" \
    "Stream the chosen language, each generated query, and any backend error to stderr as the loop runs."
# ------------------------------------------------------------------------------
# @fn _knit_ai_query()
#
# Body of 'ai query': resolve the provider config, build the query system prompt
# (gated to the pinned --lang half; schema, name map, edge model, and describe
# summary), and run the self-correcting query loop, which
# prints the formatted result (or the query alone with --query-only). The resolved
# API key stays in a local and is never logged or recorded.
# ------------------------------------------------------------------------------
_knit_ai_query() {
    local question lang format no_header separator max_iterations model query_only verbose
    question="$(knit_get_parameter "question" "$@")"
    lang="$(knit_get_parameter "lang" "$@")"
    format="$(knit_get_parameter "format" "$@")"
    no_header="$(knit_get_parameter "no-header" "$@")" || no_header="false"
    separator="$(knit_get_parameter "separator" "$@")"
    max_iterations="$(knit_get_parameter "max-iterations" "$@")"
    model="$(knit_get_parameter "model" "$@")"
    query_only="$(knit_get_parameter "query-only" "$@")" || query_only="false"
    verbose="$(knit_get_parameter "verbose" "$@")" || verbose="false"

    local api_key base_url resolved_model
    _knit_ai_resolve_config api_key base_url resolved_model "${model}"

    local system_prompt
    system_prompt="$(_knit_ai_query_system_prompt "${lang}")"

    _knit_ai_query_loop "${base_url}" "${api_key}" "${resolved_model}" \
        "${question}" "${system_prompt}" "${max_iterations}" "${verbose}" \
        "${query_only}" "${format}" "${no_header}" "${separator}" "${lang}"
}
knit_done
