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
