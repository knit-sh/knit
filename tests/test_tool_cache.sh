#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit

    # Point the tool cache at a throwaway directory so no test touches the real
    # ~/.cache/knit/tools.
    _KNIT_TOOL_CACHE_ROOT="$(mktemp -d)"

    # Start from a clean toggle state for every test.
    unset KNIT_TOOL_CACHE KNIT_OFFLINE

    # Spy for the real downloader, installed AFTER sourcing knit.sh so the source
    # does not clobber it. It records each call and "downloads" by writing the
    # destination, so a cache hit is provable by a zero call count. A test may
    # override it again (e.g. to simulate a failure).
    _spy_count_file="$(mktemp)"
    _knit_tool_download_curl() {
        local dest="$1"
        printf 'x' >> "${_spy_count_file}"
        printf 'payload' > "${dest}"
        return 0
    }
}

teardown() {
    [[ -n "${_KNIT_TOOL_CACHE_ROOT}" ]] && rm -rf "${_KNIT_TOOL_CACHE_ROOT}"
    [[ -n "${_spy_count_file}" ]] && rm -f "${_spy_count_file}"
    unset KNIT_TOOL_CACHE KNIT_OFFLINE
}

# ---------- _knit_tool_cache_enabled ----------

@test "tool cache is enabled by default" {
    run _knit_tool_cache_enabled
    [ "$status" -eq 0 ]
}

@test "tool cache stays enabled for a non-zero KNIT_TOOL_CACHE" {
    KNIT_TOOL_CACHE=1 run _knit_tool_cache_enabled
    [ "$status" -eq 0 ]
}

@test "tool cache is disabled by KNIT_TOOL_CACHE=0" {
    KNIT_TOOL_CACHE=0 run _knit_tool_cache_enabled
    [ "$status" -eq 1 ]
}

@test "KNIT_TOOL_CACHE=0 with KNIT_OFFLINE=1 is a fatal contradiction" {
    KNIT_TOOL_CACHE=0 KNIT_OFFLINE=1 run _knit_tool_cache_enabled
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be combined"* ]]
}

@test "the offline conflict does not fire while the cache is enabled" {
    KNIT_OFFLINE=1 run _knit_tool_cache_enabled
    [ "$status" -eq 0 ]
}

# ---------- _knit_tool_platform ----------

@test "platform key joins OS and architecture with a hyphen" {
    local platform; platform="$(_knit_tool_platform)"
    [ "${platform}" = "$(uname -s)-$(uname -m)" ]
    [[ "${platform}" == *-* ]]
}

# ---------- _knit_tool_toolchain_id ----------

@test "toolchain id is twelve hex characters or 'unknown'" {
    local id; id="$(_knit_tool_toolchain_id)"
    [[ "${id}" =~ ^[0-9a-f]{12}$ || "${id}" == "unknown" ]]
}

@test "toolchain id is stable across calls" {
    local a b
    a="$(_knit_tool_toolchain_id)"
    b="$(_knit_tool_toolchain_id)"
    [ "${a}" = "${b}" ]
}

# ---------- _knit_tool_cache_source_path ----------

@test "source path for a platform-independent tarball omits the platform" {
    local p
    _knit_tool_cache_source_path p sqlite 3480000 sqlite-autoconf-3480000.tar.gz
    [ "${p}" = "${_KNIT_TOOL_CACHE_ROOT}/sources/sqlite/3480000/sqlite-autoconf-3480000.tar.gz" ]
}

@test "source path for a platform-specific binary includes the platform" {
    local plat p
    plat="$(_knit_tool_platform)"
    _knit_tool_cache_source_path p jq 1.7.1 jq "${plat}"
    [ "${p}" = "${_KNIT_TOOL_CACHE_ROOT}/sources/jq/1.7.1/${plat}/jq" ]
}

# ---------- _knit_tool_cache_built_path ----------

@test "built path is keyed by tool, version, platform, and toolchain" {
    local p plat tc
    plat="$(_knit_tool_platform)"
    tc="$(_knit_tool_toolchain_id)"
    _knit_tool_cache_built_path p sqlite 3480000
    [ "${p}" = "${_KNIT_TOOL_CACHE_ROOT}/built/sqlite/3480000/${plat}/${tc}" ]
}

@test "built paths for different versions differ" {
    local a b
    _knit_tool_cache_built_path a pilotd 0.1.0
    _knit_tool_cache_built_path b pilotd 0.1.1
    [ "${a}" != "${b}" ]
}

# ---------- _knit_tool_cache_fetch_source ----------
#
# The spy downloader is installed in setup(); _spy_calls reads its call count.

_spy_calls() {
    [[ -f "${_spy_count_file}" ]] && wc -c < "${_spy_count_file}" || printf '0'
}

@test "fetch downloads on a miss and publishes into the cache" {
    local p
    _knit_tool_cache_fetch_source p pilotd 0.1.1 knit-pilotd-0.1.1.tar.gz "" \
        https://example.invalid/x.tar.gz "title"
    [ "$(_spy_calls)" -eq 1 ]
    [ "${p}" = "${_KNIT_TOOL_CACHE_ROOT}/sources/pilotd/0.1.1/knit-pilotd-0.1.1.tar.gz" ]
    [ -f "${p}" ]
}

@test "fetch serves a second provision from the cache with no download" {
    local p q
    _knit_tool_cache_fetch_source p pilotd 0.1.1 knit-pilotd-0.1.1.tar.gz "" \
        https://example.invalid/x.tar.gz "title"
    _knit_tool_cache_fetch_source q pilotd 0.1.1 knit-pilotd-0.1.1.tar.gz "" \
        https://example.invalid/x.tar.gz "title"
    [ "$(_spy_calls)" -eq 1 ]
    [ "${p}" = "${q}" ]
}

@test "fetch with the cache disabled downloads into the current directory" {
    local workdir p
    workdir="$(mktemp -d)"
    (
        cd "${workdir}"
        KNIT_TOOL_CACHE=0 _knit_tool_cache_fetch_source p pilotd 0.1.1 \
            knit-pilotd-0.1.1.tar.gz "" https://example.invalid/x.tar.gz "title"
        [ "${p}" = "knit-pilotd-0.1.1.tar.gz" ]
        [ -f "${workdir}/knit-pilotd-0.1.1.tar.gz" ]
    )
    [ "$(_spy_calls)" -eq 1 ]
    # Nothing was published into the cache.
    [ ! -d "${_KNIT_TOOL_CACHE_ROOT}/sources" ]
    rm -rf "${workdir}"
}

@test "fetch is fatal when offline and the source is not cached" {
    KNIT_OFFLINE=1 run _knit_tool_cache_fetch_source p pilotd 0.1.1 f.tar.gz "" \
        https://example.invalid/x.tar.gz t
    [ "$status" -ne 0 ]
    [[ "$output" == *"KNIT_OFFLINE=1"* ]]
    [ "$(_spy_calls)" -eq 0 ]
}

@test "fetch serves an offline hit without downloading" {
    local p q
    # Prime the cache (online), then read it back offline.
    _knit_tool_cache_fetch_source p pilotd 0.1.1 knit-pilotd-0.1.1.tar.gz "" \
        https://example.invalid/x.tar.gz "title"
    KNIT_OFFLINE=1 _knit_tool_cache_fetch_source q pilotd 0.1.1 \
        knit-pilotd-0.1.1.tar.gz "" https://example.invalid/x.tar.gz "title"
    [ "$(_spy_calls)" -eq 1 ]
    [ "${p}" = "${q}" ]
}

@test "fetch returns non-zero on a download failure" {
    _knit_tool_download_curl() { return 1; }
    run _knit_tool_cache_fetch_source p pilotd 0.1.1 knit-pilotd-0.1.1.tar.gz "" \
        https://example.invalid/x.tar.gz "title"
    [ "$status" -eq 1 ]
    # No half-written artifact was published.
    [ ! -f "${_KNIT_TOOL_CACHE_ROOT}/sources/pilotd/0.1.1/knit-pilotd-0.1.1.tar.gz" ]
}
