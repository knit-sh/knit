#!/usr/bin/env bats

# Tests for the plugin import machinery (src/plugin.sh): spec parsing, ref->commit
# resolution, the content-addressed cache (hit/miss), sourcing plugin.sh, dedup,
# version conflict, transitive imports, the --sha256 hard pin, and KNIT_OFFLINE.
# The network seam (_knit_github_resolve_commit / _knit_github_download) is stubbed
# so the whole file is offline and deterministic.

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit

    __TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PLUGIN_CACHE_ROOT="${__TEST_TMPDIR}/cache"
    MARKER="${__TEST_TMPDIR}/sourced.log"
    : > "${MARKER}"
    unset KNIT_OFFLINE
}

teardown() {
    rm -rf "${__TEST_TMPDIR}"
}

# A 40-hex commit SHA resolves to itself (no network), so tests that only need a
# cache can pin by SHA. For a non-SHA ref, stub the resolver.
SHA="0123456789abcdef0123456789abcdef01234567"

# Seed the cache for a given host/org/repo/commit with a plugin.sh that appends a
# tag to MARKER when sourced (so repeated sourcing is observable).
_seed_cache() {
    local host="$1" org="$2" repo="$3" commit="$4" tag="$5"
    local dir="${_KNIT_PLUGIN_CACHE_ROOT}/${host}/${org}/${repo}/${commit}"
    mkdir -p "${dir}"
    printf 'printf "%%s\\n" %q >> %q\n' "${tag}" "${MARKER}" > "${dir}/plugin.sh"
}

# Stub the fetch seam to materialize a plugin.sh into the destination (as the
# real _knit_github_download would after extracting a tarball) and return a fixed
# sha256 through the output nameref.
_stub_fetch() {
    # Globals (not locals): the stubbed function reads them at call time, long
    # after this helper has returned, so its locals would be gone.
    _STUB_TAG="${1:-FETCHED}"
    _STUB_DIGEST="${2:-feedface}"
    _knit_github_download() {
        local -n __out=$1
        shift
        # args: framed_run org repo dest commit
        local dest="$4"
        mkdir -p "${dest}"
        printf 'printf "%%s\\n" %q >> %q\n' "${_STUB_TAG}" "${MARKER}" > "${dest}/plugin.sh"
        __out="${_STUB_DIGEST}"
    }
}

# ---------- spec parsing ----------

@test "parse_spec expands a bare name to the blessed namespace" {
    local h o r f
    _knit_plugin_parse_spec h o r f "spack"
    [ "${h}" = "github.com" ]
    [ "${o}" = "knit-sh" ]
    [ "${r}" = "knit-spack" ]
    [ "${f}" = "" ]
}

@test "parse_spec keeps a ref on the bare-name form" {
    local h o r f
    _knit_plugin_parse_spec h o r f "spack@v1.2.0"
    [ "${r}" = "knit-spack" ]
    [ "${f}" = "v1.2.0" ]
}

@test "parse_spec defaults the host for an org/repo spec" {
    local h o r f
    _knit_plugin_parse_spec h o r f "knit-sh/knit-plot"
    [ "${h}" = "github.com" ]
    [ "${o}" = "knit-sh" ]
    [ "${r}" = "knit-plot" ]
}

@test "parse_spec reads host/org/repo and strips the https scheme" {
    local h o r f
    _knit_plugin_parse_spec h o r f "https://example.com/acme/thing@main"
    [ "${h}" = "example.com" ]
    [ "${o}" = "acme" ]
    [ "${r}" = "thing" ]
    [ "${f}" = "main" ]
}

@test "parse_spec is fatal on a malformed (too many parts) spec" {
    run _knit_plugin_parse_spec h o r f "a/b/c/d"
    [ "$status" -eq 1 ]
    [[ "$output" == *"malformed"* ]]
}

# ---------- resolve ----------

@test "resolve_commit returns a full SHA without touching the network" {
    _knit_github_resolve_commit() { echo "SHOULD_NOT_BE_CALLED"; }
    local c
    _knit_plugin_resolve_commit c "github.com" "o" "r" "${SHA}"
    [ "${c}" = "${SHA}" ]
}

@test "resolve_commit delegates a non-SHA ref to the host resolver" {
    _knit_github_resolve_commit() { printf 'resolvedsha'; }
    local c
    _knit_plugin_resolve_commit c "github.com" "o" "r" "v1.0"
    [ "${c}" = "resolvedsha" ]
}

@test "resolve_commit is fatal for a non-SHA ref under KNIT_OFFLINE" {
    KNIT_OFFLINE=1
    run _knit_plugin_resolve_commit c "github.com" "o" "r" "main"
    [ "$status" -eq 1 ]
    [[ "$output" == *"KNIT_OFFLINE"* ]]
}

# ---------- cache hit ----------

@test "knit_import sources plugin.sh from the cache on a hit (no fetch)" {
    _seed_cache "github.com" "knit-sh" "knit-demo" "${SHA}" "DEMO"
    _knit_github_download() { echo "FETCH_SHOULD_NOT_RUN"; return 1; }

    knit_import "demo@${SHA}"
    [ "$(cat "${MARKER}")" = "DEMO" ]
}

# ---------- cache miss -> fetch ----------

@test "knit_import fetches on a cache miss then sources the plugin" {
    _stub_fetch "FETCHED"
    knit_import "demo@${SHA}"
    [ "$(cat "${MARKER}")" = "FETCHED" ]
    # The fetched tree is published into the content-addressed cache.
    [ -f "${_KNIT_PLUGIN_CACHE_ROOT}/github.com/knit-sh/knit-demo/${SHA}/plugin.sh" ]
}

# ---------- dedup ----------

@test "knit_import sources a repeated import of the same id only once" {
    _seed_cache "github.com" "knit-sh" "knit-demo" "${SHA}" "ONCE"
    knit_import "demo@${SHA}"
    knit_import "demo@${SHA}"
    [ "$(wc -l < "${MARKER}")" -eq 1 ]
}

@test "knit_import treats an unpinned repeat as a dedup, not a conflict" {
    _seed_cache "github.com" "knit-sh" "knit-demo" "${SHA}" "ONCE"
    _knit_github_resolve_commit() { printf '%s' "${SHA}"; }
    knit_import "demo@${SHA}"
    run knit_import "demo"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "${MARKER}")" -eq 1 ]
}

# ---------- version conflict ----------

@test "knit_import is fatal when the same id is imported at two different refs" {
    _knit_github_resolve_commit() { printf 'anysha'; }
    _stub_fetch
    knit_import "demo@v1"
    run knit_import "demo@v2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflicting refs"* ]]
}

# ---------- transitive imports ----------

@test "knit_import sources a dependency before the dependent continues" {
    # The dependent's plugin.sh imports a dependency, then records itself; the
    # dependency must appear first in the marker.
    local dep="${_KNIT_PLUGIN_CACHE_ROOT}/github.com/knit-sh/knit-dep/${SHA}"
    mkdir -p "${dep}"
    printf 'printf "%%s\\n" DEP >> %q\n' "${MARKER}" > "${dep}/plugin.sh"

    local top="${_KNIT_PLUGIN_CACHE_ROOT}/github.com/knit-sh/knit-top/${SHA}"
    mkdir -p "${top}"
    {
        printf 'knit_import "dep@%s"\n' "${SHA}"
        printf 'printf "%%s\\n" TOP >> %q\n' "${MARKER}"
    } > "${top}/plugin.sh"

    knit_import "top@${SHA}"
    [ "$(cat "${MARKER}")" = "$(printf 'DEP\nTOP')" ]
}

# ---------- --sha256 hard pin ----------

@test "knit_import accepts a matching --sha256 pin" {
    _stub_fetch "OK" "abc123"
    knit_import "demo@${SHA}" --sha256 abc123
    [ "$(cat "${MARKER}")" = "OK" ]
}

@test "knit_import is fatal on a --sha256 mismatch" {
    _stub_fetch "NO" "abc123"
    run knit_import "demo@${SHA}" --sha256 deadbeef
    [ "$status" -eq 1 ]
    [[ "$output" == *"sha256 mismatch"* ]]
}

# ---------- KNIT_OFFLINE ----------

@test "knit_import sources a cached SHA offline" {
    _seed_cache "github.com" "knit-sh" "knit-demo" "${SHA}" "CACHED"
    KNIT_OFFLINE=1
    _knit_github_download() { echo "FETCH_SHOULD_NOT_RUN"; return 1; }
    knit_import "demo@${SHA}"
    [ "$(cat "${MARKER}")" = "CACHED" ]
}

@test "knit_import is fatal for an uncached SHA offline" {
    KNIT_OFFLINE=1
    run knit_import "demo@${SHA}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not cached"* ]]
}

# ---------- host validation ----------

@test "knit_import rejects a non-github host for now" {
    run knit_import "example.com/acme/thing@${SHA}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not supported"* ]]
}
