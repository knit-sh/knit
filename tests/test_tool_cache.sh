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

# ---------- built-binary cache: install + publish ----------

# Make a fake installed prefix tree with a runnable "bin/<name>".
_fake_prefix() {
    local dir="$1" name="$2"
    mkdir -p "${dir}/bin"
    printf '#!/bin/sh\necho ok\n' > "${dir}/bin/${name}"
    chmod +x "${dir}/bin/${name}"
}

@test "install reports a miss when nothing is cached" {
    local dest; dest="$(mktemp -d)/sqlite"
    run _knit_tool_cache_install sqlite 3480000 "${dest}"
    [ "$status" -eq 1 ]
    [ ! -e "${dest}" ]
}

@test "publish then install round-trips a built tree" {
    local work; work="$(mktemp -d)"
    _fake_prefix "${work}/src" sqlite3

    _knit_tool_cache_publish_built sqlite 3480000 "${work}/src"
    local built
    _knit_tool_cache_built_path built sqlite 3480000
    [ -x "${built}/bin/sqlite3" ]

    _knit_tool_cache_install sqlite 3480000 "${work}/dest"
    [ -x "${work}/dest/bin/sqlite3" ]
    rm -rf "${work}"
}

@test "install overwrites an existing destination prefix" {
    local work; work="$(mktemp -d)"
    _fake_prefix "${work}/src" sqlite3
    _knit_tool_cache_publish_built sqlite 3480000 "${work}/src"
    # A stale file under dest must not survive the install.
    mkdir -p "${work}/dest/bin"
    printf 'stale' > "${work}/dest/stale"
    _knit_tool_cache_install sqlite 3480000 "${work}/dest"
    [ -x "${work}/dest/bin/sqlite3" ]
    [ ! -e "${work}/dest/stale" ]
    rm -rf "${work}"
}

@test "publish is a no-op when the key is already populated" {
    local work; work="$(mktemp -d)"
    _fake_prefix "${work}/a" sqlite3
    _fake_prefix "${work}/b" sqlite3
    printf 'marker' > "${work}/a/bin/sqlite3"   # distinguish the two trees

    _knit_tool_cache_publish_built sqlite 3480000 "${work}/a"
    _knit_tool_cache_publish_built sqlite 3480000 "${work}/b"   # must not replace
    local built
    _knit_tool_cache_built_path built sqlite 3480000
    [ "$(cat "${built}/bin/sqlite3")" = "marker" ]
    rm -rf "${work}"
}

# ---------- _knit_tool_smoke_test ----------

_make_bin() {
    local path="$1" body="$2"
    printf '#!/bin/sh\n%s\n' "${body}" > "${path}"
    chmod +x "${path}"
}

@test "smoke test passes a runnable binary" {
    local bin; bin="$(mktemp -d)/b"
    _make_bin "${bin}" "exit 0"
    run _knit_tool_smoke_test "${bin}" --version
    [ "$status" -eq 0 ]
    rm -rf "$(dirname "${bin}")"
}

@test "smoke test passes a binary that exits non-zero (it still ran)" {
    local bin; bin="$(mktemp -d)/b"
    _make_bin "${bin}" "exit 2"
    run _knit_tool_smoke_test "${bin}"
    [ "$status" -eq 0 ]
    rm -rf "$(dirname "${bin}")"
}

@test "smoke test rejects a non-executable binary" {
    local bin; bin="$(mktemp -d)/b"
    printf 'not a program' > "${bin}"
    run _knit_tool_smoke_test "${bin}"
    [ "$status" -eq 1 ]
    rm -rf "$(dirname "${bin}")"
}

@test "smoke test rejects a binary that hangs" {
    local bin; bin="$(mktemp -d)/b"
    _make_bin "${bin}" "sleep 5"
    _KNIT_TOOL_SMOKE_TIMEOUT=1 run _knit_tool_smoke_test "${bin}"
    [ "$status" -eq 1 ]
    rm -rf "$(dirname "${bin}")"
}

@test "smoke test rejects a binary killed by a signal" {
    local bin; bin="$(mktemp -d)/b"
    _make_bin "${bin}" 'kill -9 $$'
    run _knit_tool_smoke_test "${bin}"
    [ "$status" -eq 1 ]
    rm -rf "$(dirname "${bin}")"
}

@test "install rejects and purges a poisoned built entry" {
    local work; work="$(mktemp -d)"
    _fake_prefix "${work}/src" sqlite3
    _knit_tool_cache_publish_built sqlite 3480000 "${work}/src"
    local built
    _knit_tool_cache_built_path built sqlite 3480000
    chmod -x "${built}/bin/sqlite3"   # make the cached binary un-runnable

    run _knit_tool_cache_install sqlite 3480000 "${work}/dest" bin/sqlite3 --version
    [ "$status" -eq 1 ]
    [ ! -e "${work}/dest" ]
    # The poisoned entry was discarded so a rebuild can republish a good one.
    [ ! -d "${built}" ]
    rm -rf "${work}"
}

@test "install and publish are no-ops when the cache is disabled" {
    local work; work="$(mktemp -d)"
    _fake_prefix "${work}/src" sqlite3
    KNIT_TOOL_CACHE=0 _knit_tool_cache_publish_built sqlite 3480000 "${work}/src"
    [ ! -d "${_KNIT_TOOL_CACHE_ROOT}/built" ]
    KNIT_TOOL_CACHE=0 run _knit_tool_cache_install sqlite 3480000 "${work}/dest"
    [ "$status" -eq 1 ]
    [ ! -e "${work}/dest" ]
    rm -rf "${work}"
}

# ---------- _knit_build_sqlite cascade ----------

@test "_knit_build_sqlite installs from the built cache with no compile" {
    local work; work="$(mktemp -d)"
    _KNIT_PREFIX="${work}/.knit"
    mkdir -p "${_KNIT_PREFIX}"

    # Seed a built-cache entry for the current sqlite version.
    local version="${_KNIT_SQLITE_SOURCE_NAME##*-}"
    _fake_prefix "${work}/built-src" sqlite3
    _knit_tool_cache_publish_built sqlite "${version}" "${work}/built-src"

    # A compile or a download must not happen on a built hit.
    _knit_tool_cache_fetch_source() { echo "FETCHED" >&2; return 1; }
    _knit_sqlite_framed_run() { echo "COMPILED" >&2; return 1; }

    run _knit_build_sqlite
    [ "$status" -eq 0 ]
    [[ "$output" != *"FETCHED"* ]]
    [[ "$output" != *"COMPILED"* ]]
    [ -x "${_KNIT_PREFIX}/sqlite/bin/sqlite3" ]
    rm -rf "${work}"
}

@test "_knit_build_cypher_to_sql installs from the built cache with no compile" {
    local work; work="$(mktemp -d)"
    _KNIT_PREFIX="${work}/.knit"
    mkdir -p "${_KNIT_PREFIX}"

    _fake_prefix "${work}/built-src" knit-cypher-to-sql
    _knit_tool_cache_publish_built cypher-to-sql 0.1.0 "${work}/built-src"

    _knit_tool_cache_fetch_source() { echo "FETCHED" >&2; return 1; }
    _knit_cypher_to_sql_framed_run() { echo "COMPILED" >&2; return 1; }

    run _knit_build_cypher_to_sql 0.1.0 https://example.invalid/x.tar.gz
    [ "$status" -eq 0 ]
    [[ "$output" != *"FETCHED"* ]]
    [[ "$output" != *"COMPILED"* ]]
    [ -x "${_KNIT_PREFIX}/knit-cypher-to-sql/bin/knit-cypher-to-sql" ]
    rm -rf "${work}"
}

@test "_knit_build_pilotd installs from the built cache with no compile" {
    local work; work="$(mktemp -d)"
    _KNIT_PREFIX="${work}/.knit"
    mkdir -p "${_KNIT_PREFIX}"

    _fake_prefix "${work}/built-src" knit-pilotd
    _knit_tool_cache_publish_built pilotd 0.1.1 "${work}/built-src"

    _knit_tool_cache_fetch_source() { echo "FETCHED" >&2; return 1; }
    knit_framed_run() { echo "COMPILED" >&2; return 1; }

    run _knit_build_pilotd 0.1.1 https://example.invalid/x.tar.gz
    [ "$status" -eq 0 ]
    [[ "$output" != *"FETCHED"* ]]
    [[ "$output" != *"COMPILED"* ]]
    [ -x "${_KNIT_PREFIX}/knit-pilotd/bin/knit-pilotd" ]
    rm -rf "${work}"
}

# ---------- _knit_download_jq single-layer path ----------

@test "_knit_download_jq installs jq from the source cache with no download" {
    local work; work="$(mktemp -d)"
    _KNIT_JQ_EXE="${work}/jq/bin/jq"

    # Seed the source cache for the current jq version and platform.
    local cached
    _knit_tool_cache_source_path cached jq "${_KNIT_JQ_VERSION}" jq "$(_knit_tool_platform)"
    mkdir -p "$(dirname "${cached}")"
    printf '#!/bin/sh\necho jq\n' > "${cached}"

    _knit_tool_download_curl() { echo "DOWNLOADED" >&2; return 1; }

    run _knit_download_jq
    [ "$status" -eq 0 ]
    [[ "$output" != *"DOWNLOADED"* ]]
    [ -x "${_KNIT_JQ_EXE}" ]
    rm -rf "${work}"
}

@test "_knit_download_jq with the cache disabled downloads straight to the install path" {
    local work; work="$(mktemp -d)"
    _KNIT_JQ_EXE="${work}/jq/bin/jq"

    _knit_tool_download_curl() { printf 'jqbin' > "$1"; return 0; }

    KNIT_TOOL_CACHE=0 run _knit_download_jq
    [ "$status" -eq 0 ]
    [ -x "${_KNIT_JQ_EXE}" ]
    # Nothing was published into the cache.
    [ ! -d "${_KNIT_TOOL_CACHE_ROOT}/sources" ]
    rm -rf "${work}"
}

# ---------- offline behavior ----------

@test "offline built-cache hit installs sqlite with no network" {
    local work; work="$(mktemp -d)"
    _KNIT_PREFIX="${work}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    local version="${_KNIT_SQLITE_SOURCE_NAME##*-}"
    _fake_prefix "${work}/built-src" sqlite3
    _knit_tool_cache_publish_built sqlite "${version}" "${work}/built-src"

    # Any attempt to fetch a source would be a bug offline.
    _knit_tool_cache_fetch_source() { echo "FETCHED" >&2; return 1; }

    KNIT_OFFLINE=1 run _knit_build_sqlite
    [ "$status" -eq 0 ]
    [[ "$output" != *"FETCHED"* ]]
    [ -x "${_KNIT_PREFIX}/sqlite/bin/sqlite3" ]
    rm -rf "${work}"
}

@test "offline with no cached sqlite source is a clear fatal" {
    local work; work="$(mktemp -d)"
    _KNIT_PREFIX="${work}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    # Neither a built entry nor a source entry is cached.
    KNIT_OFFLINE=1 run _knit_build_sqlite
    [ "$status" -ne 0 ]
    [[ "$output" == *"KNIT_OFFLINE=1"* ]]
    rm -rf "${work}"
}
