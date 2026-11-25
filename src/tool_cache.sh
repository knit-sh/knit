#!/bin/bash

## @file tool_cache.sh

# ------------------------------------------------------------------------------
# @var _KNIT_TOOL_CACHE_ROOT
#
# Root of the shared cache for the framework's own provisioned tools (sqlite, jq,
# knit-cypher-to-sql, knit-pilotd), a sibling of the plugin cache
# (_KNIT_PLUGIN_CACHE_ROOT). A tool is downloaded and built once into the cache
# and every later provision at the same version is an offline hit. Two layers
# live under it: "sources/" (downloaded tarballs and prebuilt binaries) and
# "built/" (installed prefix trees, keyed by platform and toolchain). Defaults
# under XDG_CACHE_HOME (falling back to ~/.cache); a test or a reproducer may
# override it. The cache is a provisioning accelerator, not part of ".knit".
# ------------------------------------------------------------------------------
declare -g _KNIT_TOOL_CACHE_ROOT
_KNIT_TOOL_CACHE_ROOT="${XDG_CACHE_HOME:-${HOME}/.cache}/knit/tools"

# ------------------------------------------------------------------------------
# @fn _knit_tool_cache_enabled()
#
# Report whether the tool cache is in use. The cache is on by default and off
# only when KNIT_TOOL_CACHE is exactly "0" (any other value, or unset, leaves it
# on) — the escape hatch for a host where the cache directory is unwritable,
# distrusted, or holding a bad entry the user wants to bypass. When the cache is
# disabled, every tool is downloaded and built fresh and nothing is published.
#
# Disabling the cache while KNIT_OFFLINE=1 is a contradiction (no cache and no
# network, so nothing could be provisioned); that combination is a fatal error.
#
# @return 0 when the cache is enabled, 1 when it is disabled.
# ------------------------------------------------------------------------------
_knit_tool_cache_enabled() {
    if [[ "${KNIT_TOOL_CACHE:-}" == "0" ]]; then
        if [[ "${KNIT_OFFLINE:-}" == "1" ]]; then
            knit_fatal "KNIT_TOOL_CACHE=0 and KNIT_OFFLINE=1 cannot be combined: \
the tool cache is disabled and the network is forbidden, so no tool can be \
provisioned."
        fi
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_tool_platform()
#
# Print the platform key for a cached tool: the operating system and machine
# architecture joined by a hyphen, e.g. "Linux-x86_64". It keys the
# platform-specific layers (the prebuilt jq binary in the source cache, and every
# built prefix tree) so an artifact from one platform is never installed on
# another.
# ------------------------------------------------------------------------------
_knit_tool_platform() {
    printf '%s-%s' "$(uname -s)" "$(uname -m)"
}

# ------------------------------------------------------------------------------
# @fn _knit_tool_toolchain_id()
#
# Print a short, stable identifier of the C toolchain the current host builds
# with. A built prefix tree is keyed by this id (on top of the platform) so a
# binary compiled against one compiler/ABI is never installed on an incompatible
# one. The id is the first twelve hex characters of the sha256 of the compiler's
# target triple ("cc -dumpmachine") and version banner ("cc --version"). When no
# C compiler is found the id is "unknown" (a build would fail anyway, but the
# key stays well-formed).
# ------------------------------------------------------------------------------
_knit_tool_toolchain_id() {
    local cc="${CC:-cc}"
    if ! command -v "${cc}" >/dev/null 2>&1; then
        printf 'unknown'
        return 0
    fi
    local triple banner digest
    triple="$("${cc}" -dumpmachine 2>/dev/null)"
    banner="$("${cc}" --version 2>/dev/null | head -n 1)"
    digest="$(printf '%s\n%s' "${triple}" "${banner}" | sha256sum)"
    printf '%s' "${digest:0:12}"
}

# ------------------------------------------------------------------------------
# @fn _knit_tool_cache_source_path()
#
# Return, by nameref, the path a tool's downloaded source artifact lives at in
# the cache: "<root>/sources/<tool>/<version>[/<platform>]/<filename>". The
# platform segment is included only for a platform-specific artifact (the
# prebuilt jq binary); the tarball sources omit it. The path is returned whether
# or not the file exists — the caller tests for existence.
#
# @param[out] path_out  Nameref receiving the source artifact path.
# @param[in]  tool      Tool key ("sqlite", "jq", "cypher-to-sql", "pilotd").
# @param[in]  version   Version token keying the artifact.
# @param[in]  filename  Artifact file name (tarball or binary name).
# @param[in]  platform  Platform key, or empty for a platform-independent source.
# ------------------------------------------------------------------------------
_knit_tool_cache_source_path() {
    local -n __knit_ret=$1
    local tool="$2"
    local version="$3"
    local filename="$4"
    local platform="${5:-}"
    local dir="${_KNIT_TOOL_CACHE_ROOT}/sources/${tool}/${version}"
    [[ -n "${platform}" ]] && dir="${dir}/${platform}"
    __knit_ret="${dir}/${filename}"
}

# ------------------------------------------------------------------------------
# @fn _knit_tool_cache_built_path()
#
# Return, by nameref, the directory a tool's built prefix tree lives at in the
# cache: "<root>/built/<tool>/<version>/<platform>/<toolchain>". A hit here is
# copied into ".knit/<tool>" to skip the compile entirely; the platform and
# toolchain segments make the hit version-, platform-, and ABI-matched. The path
# is returned whether or not the tree exists — the caller tests for existence.
#
# @param[out] path_out  Nameref receiving the built-tree directory.
# @param[in]  tool      Tool key ("sqlite", "cypher-to-sql", "pilotd").
# @param[in]  version   Version token keying the tree.
# ------------------------------------------------------------------------------
_knit_tool_cache_built_path() {
    local -n __knit_ret=$1
    local tool="$2"
    local version="$3"
    __knit_ret="${_KNIT_TOOL_CACHE_ROOT}/built/${tool}/${version}/\
$(_knit_tool_platform)/$(_knit_tool_toolchain_id)"
}
