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
