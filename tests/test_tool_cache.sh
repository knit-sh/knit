#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit

    # Point the tool cache at a throwaway directory so no test touches the real
    # ~/.cache/knit/tools.
    _KNIT_TOOL_CACHE_ROOT="$(mktemp -d)"

    # Start from a clean toggle state for every test.
    unset KNIT_TOOL_CACHE KNIT_OFFLINE
}

teardown() {
    [[ -n "${_KNIT_TOOL_CACHE_ROOT}" ]] && rm -rf "${_KNIT_TOOL_CACHE_ROOT}"
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
