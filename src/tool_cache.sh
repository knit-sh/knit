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

# ------------------------------------------------------------------------------
# @fn _knit_tool_download_curl()
#
# Download a URL to a destination path inside a titled frame, with the retry and
# fail-on-HTTP-error behavior every tool download shares. A GITHUB_TOKEN/GH_TOKEN
# (when set) is attached only to a github.com URL — never to a third-party host,
# so the token is not leaked to, e.g., sqlite.org. The combined output goes to
# _KNIT_TRACE_FILE so a failure points at the trace.
#
# @param[in] dest  Path to write the downloaded artifact to.
# @param[in] url   URL to download.
# @param[in] title Title shown on the download frame's top border.
# @return The curl exit status (0 on success).
# ------------------------------------------------------------------------------
_knit_tool_download_curl() {
    local dest="$1"
    local url="$2"
    local title="$3"
    # -f makes an HTTP error status (e.g. a rate-limited GitHub response) a clean
    # failure instead of a saved error body that would later fail to extract;
    # --retry rides out a transient network error.
    local -a curl_args=(-fL --retry 3 --retry-delay 2 -o "${dest}")
    if [[ "${url}" == https://github.com/* || "${url}" == https://*.github.com/* ]]; then
        # The token lifts the low anonymous rate limit CI runners share by
        # address; it is only ever sent to GitHub.
        local gh_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
        [[ -n "${gh_token}" ]] && curl_args+=(-H "Authorization: Bearer ${gh_token}")
    fi
    knit_framed_run "${title}" curl "${curl_args[@]}" "${url}"
}

# ------------------------------------------------------------------------------
# @fn _knit_tool_cache_fetch_source()
#
# Resolve a tool's downloaded source artifact (a tarball or a prebuilt binary) to
# a local path the caller can build from, using the source-artifact cache when it
# is enabled. The returned path is in the cache on a hit, or freshly downloaded on
# a miss; with the cache disabled (KNIT_TOOL_CACHE=0) the artifact is downloaded
# into the current directory (under its bare filename) and that relative path is
# returned, so the caller's own cleanup removes it.
#
# A cache miss downloads to a temporary sibling and publishes it atomically, so a
# concurrent provision never sees a half-written artifact. KNIT_OFFLINE=1 with no
# cached artifact is fatal (it forbids the download). A download failure returns
# non-zero without a message, leaving the caller to emit its tool-specific fatal.
#
# @param[out] path_out  Nameref receiving the path to build from.
# @param[in]  tool      Tool key ("sqlite", "cypher-to-sql", "pilotd").
# @param[in]  version   Version token keying the artifact.
# @param[in]  filename  Artifact file name (also the download destination when the
#             cache is disabled).
# @param[in]  platform  Platform key, or empty for a platform-independent source.
# @param[in]  url       URL to download the artifact from on a miss.
# @param[in]  title     Title shown on the download frame.
# @return 0 on a hit or a successful download, 1 on a download failure.
# ------------------------------------------------------------------------------
_knit_tool_cache_fetch_source() {
    local -n __knit_ret=$1
    local tool="$2"
    local version="$3"
    local filename="$4"
    local platform="$5"
    local url="$6"
    local title="$7"

    # Cache off: download into the current directory and hand back that path; the
    # caller deletes it with the rest of its build scratch.
    if ! _knit_tool_cache_enabled; then
        _knit_tool_download_curl "${filename}" "${url}" "${title}" || return 1
        __knit_ret="${filename}"
        return 0
    fi

    local cached
    _knit_tool_cache_source_path cached "${tool}" "${version}" "${filename}" "${platform}"
    if [[ -f "${cached}" ]]; then
        knit_trace "Using cached ${tool} source at ${cached}."
        __knit_ret="${cached}"
        return 0
    fi

    if [[ "${KNIT_OFFLINE:-}" == "1" ]]; then
        knit_fatal "KNIT_OFFLINE=1 is set but no cached ${tool} source is \
available at ${cached}; cannot download it."
    fi

    mkdir -p "$(dirname "${cached}")"
    local tmp
    tmp="$(mktemp "${cached}.XXXXXX")"
    if ! _knit_tool_download_curl "${tmp}" "${url}" "${title}"; then
        rm -f "${tmp}"
        return 1
    fi
    mv -f "${tmp}" "${cached}"
    knit_trace "Cached ${tool} source at ${cached}."
    __knit_ret="${cached}"
    return 0
}
