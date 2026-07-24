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
# is the single writer shared by `ai init` and bootstrap's `--ai-*` options, so
# both produce byte-for-byte identical metadata.
#
# Only env-var *names* and non-secret defaults are stored; no API key ever
# reaches the database.
#
# @param api_key_env Name of the env var holding the API key.
# @param base_url_env Name of the env var holding the endpoint base URL.
# @param model_env Name of the env var holding the model id.
# @param base_url Literal fallback base URL.
# @param model Literal fallback model id.
# @param overwrite "true" to overwrite existing keys, anything else to fail on
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
# Fatals (with a hint mentioning both `ai init` and `bootstrap --ai-*`) when the
# provider is unconfigured, the API key env var is empty/unset, or no model can
# be resolved. The resolved API key is returned only through the caller-named
# output variable; it is never logged, traced, or echoed.
#
# @param __knit_ret1 Name of the variable to hold the resolved API key.
# @param __knit_ret2 Name of the variable to hold the resolved base URL.
# @param __knit_ret3 Name of the variable to hold the resolved model id.
# @param model_override Optional model id that takes precedence over metadata.
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
        knit_fatal "AI provider is not configured. Run \"%s ai init --api-key-env <NAME>\" or bootstrap with --ai-api-key-env." \
            "${KNIT_SCRIPT_NAME}"
    fi

    local api_key="${!api_key_env}"
    if [[ -z "${api_key}" ]]; then
        knit_fatal "AI API key environment variable \$%s is empty or unset." \
            "${api_key_env}"
    fi

    local base_url=""
    [[ -n "${base_url_env}" ]] && base_url="${!base_url_env}"
    [[ -z "${base_url}" ]] && base_url="${base_url_literal}"
    [[ -z "${base_url}" ]] && base_url="${_KNIT_AI_DEFAULT_BASE_URL}"

    local model="${model_override}"
    [[ -z "${model}" && -n "${model_env}" ]] && model="${!model_env}"
    [[ -z "${model}" ]] && model="${model_literal}"
    if [[ -z "${model}" ]]; then
        knit_fatal "No AI model configured. Pass --model, set the model env var, or configure a default with \"%s ai init --model <id>\" (or bootstrap --ai-model)." \
            "${KNIT_SCRIPT_NAME}"
    fi

    __knit_ret1="${api_key}"
    __knit_ret2="${base_url}"
    __knit_ret3="${model}"
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
# @param base_url Endpoint base URL (without a trailing /chat/completions).
# @param api_key Resolved API key (kept local; never logged).
# @param model Model id.
# @param messages_json JSON array of chat messages.
# @param tools_json Optional JSON array of tool definitions (omitted when empty).
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

    local resp
    resp=$(curl -s -S -K "${cfg}" 2>>"${_KNIT_TRACE_FILE}")
    local curl_status=$?
    rm -f "${cfg}" "${body_file}"

    if (( curl_status != 0 )); then
        knit_fatal "AI request to %s failed (curl exit %d). See %s." \
            "${url}" "${curl_status}" "${_KNIT_TRACE_FILE}"
    fi

    local err
    err=$(printf '%s' "${resp}" | _knit_jq -r '.error.message // empty' 2>/dev/null)
    if [[ -n "${err}" ]]; then
        local etype
        etype=$(printf '%s' "${resp}" | _knit_jq -r '.error.type // "error"' 2>/dev/null)
        knit_fatal "AI provider error (%s): %s" "${etype}" "${err}"
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
# @param sql The SQL statement to check.
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
# @param text The text to bound.
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
# @param only Optional comma-separated command list (colon form, e.g. "a,b:c").
# @param recursive "true" to also include the selected commands' subcommands.
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
# @param command The command whose help to show (space-separated for nesting).
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
# @param sql The SQL statement to run.
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
# @param id The job UUID.
# @param stream One of "stdout" (default), "stderr", or "script".
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
# @param name The tool name (e.g. "knit_describe").
# @param args_json JSON object string of the tool's arguments.
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
# Registration of the ai command group.
#
# `ai` commands read/write the metadata table and/or the run/job database, so
# they are NOT usable before bootstrap: the central runtime guard refuses them
# uniformly until the experiment is bootstrapped.
# ------------------------------------------------------------------------------
knit_register knit_empty ai "Talk to your experiment in natural language."
_knit_is_builtin
knit_without_provenance
knit_done

# ------------------------------------------------------------------------------
# Registration of 'ai init'.
# ------------------------------------------------------------------------------
knit_register _knit_ai_init "ai:init" \
    "Configure the AI provider (env-var names and non-secret defaults)."
_knit_is_builtin
knit_without_provenance
knit_with_required "api-key-env:string" \
    "Name of the env var holding the API key (e.g. OPENAI_API_KEY)."
knit_with_optional "base-url-env:string" "" \
    "Name of the env var holding the endpoint base URL (e.g. OPENAI_BASE_URL)."
knit_with_optional "model-env:string" "" \
    "Name of the env var holding the model id (e.g. KNIT_AI_MODEL)."
knit_with_optional "base-url:string" "https://api.openai.com/v1" \
    "Literal fallback base URL used when the base-url env var is unset."
knit_with_optional "model:string" "" \
    "Literal fallback model id used when the model env var is unset."
knit_with_flag "force" "Overwrite existing ai.* metadata keys."
# ------------------------------------------------------------------------------
# @fn _knit_ai_init()
#
# Body of 'ai init': record provider-access metadata as `ai.*` key/value pairs.
# Delegates to _knit_ai_store_config so bootstrap-time and init-time config are
# identical. --force overwrites existing keys.
# ------------------------------------------------------------------------------
_knit_ai_init() {
    local api_key_env base_url_env model_env base_url model force
    api_key_env="$(knit_get_parameter "api-key-env" "$@")"
    base_url_env="$(knit_get_parameter "base-url-env" "$@")"
    model_env="$(knit_get_parameter "model-env" "$@")"
    base_url="$(knit_get_parameter "base-url" "$@")"
    model="$(knit_get_parameter "model" "$@")"
    force="$(knit_get_parameter "force" "$@")" || force="false"

    _knit_ai_store_config "${api_key_env}" "${base_url_env}" "${model_env}" \
        "${base_url}" "${model}" "${force}"
}
knit_done
