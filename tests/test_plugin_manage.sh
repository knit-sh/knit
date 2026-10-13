#!/usr/bin/env bats

# Tests for the plugin management commands (src/plugin.sh, M10): "knit plugins
# list" and "knit plugins show". Rows are seeded through the M9 bootstrap hook so
# the tests exercise real recorded data; no network is involved.

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_require_sqlite
    knit_test_db_setup

    __TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${__TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    _KNIT_PLUGIN_CACHE_ROOT="${__TEST_TMPDIR}/cache"
    _KNIT_PLUGIN_LOCKFILE="${__TEST_TMPDIR}/knit-plugins.lock"

    _KNIT_PLUGIN_ORDER=()
    _KNIT_PLUGIN_SPEC=()
    _KNIT_PLUGIN_CHECKSUM=()
    _KNIT_PLUGIN_IMPORTED_BY=()
    _KNIT_PLUGIN_IMPORT_STACK=()
    _KNIT_PLUGIN_REFS=()
    _KNIT_PLUGIN_COMMITS=()
    _KNIT_PLUGIN_TABLE_ENSURED=""
}

teardown() {
    rm -rf "${__TEST_TMPDIR}"
    knit_test_db_teardown
}

SPACK_COMMIT="a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f80910"
BASE_COMMIT="1111222233334444555566667777888899990000"

# Seed one plugin into the in-memory order set with a cache tree.
_seed_import() {
    local id="$1" spec="$2" ref="$3" commit="$4" checksum="$5" importer="$6"
    _KNIT_PLUGIN_ORDER+=("${id}")
    _KNIT_PLUGIN_SPEC["${id}"]="${spec}"
    _KNIT_PLUGIN_REFS["${id}"]="${ref}"
    _KNIT_PLUGIN_COMMITS["${id}"]="${commit}"
    _KNIT_PLUGIN_CHECKSUM["${id}"]="${checksum}"
    _KNIT_PLUGIN_IMPORTED_BY["${id}"]="${importer}"
    local dir="${_KNIT_PLUGIN_CACHE_ROOT}/${id}/${commit}"
    mkdir -p "${dir}"
    printf 'body\n' > "${dir}/plugin.sh"
}

# Seed two plugins (spack imported by the experiment, base imported by spack) and
# record them into the database.
_seed_two() {
    _seed_import "github.com/knit-sh/knit-spack" "spack@main" "main" \
        "${SPACK_COMMIT}" "deadbeef" ""
    _seed_import "github.com/knit-sh/knit-base" "base" "" \
        "${BASE_COMMIT}" "" "github.com/knit-sh/knit-spack"
    _knit_plugin_bootstrap >/dev/null 2>&1
}

# ---------- list ----------

@test "list reports nothing when no plugin was recorded" {
    run knit plugins list
    [ "$status" -eq 0 ]
    [[ "$output" == *"No plugins have been imported."* ]]
}

@test "list prints a header and one aligned row per plugin" {
    _seed_two
    run knit plugins list
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLUGIN"*"REF"*"COMMIT"*"IMPORTED BY"* ]]
    [[ "$output" == *"github.com/knit-sh/knit-spack"*"main"* ]]
    [[ "$output" == *"github.com/knit-sh/knit-base"* ]]
}

@test "list shortens the commit and labels an empty ref and importer" {
    _seed_two
    run knit plugins list
    # The resolved commit is shown as its first 12 characters.
    [[ "$output" == *"${SPACK_COMMIT:0:12}"* ]]
    [[ "$output" != *"${SPACK_COMMIT}"* ]]
    # An empty ref shows as <default>; the experiment is the default importer.
    [[ "$output" == *"<default>"* ]]
    [[ "$output" == *"(experiment)"* ]]
}

# ---------- show ----------

@test "show selects a plugin by its repository short name" {
    _seed_two
    run knit plugins show --id spack
    [ "$status" -eq 0 ]
    [[ "$output" == *"Plugin:       github.com/knit-sh/knit-spack"* ]]
    [[ "$output" == *"Spec:         spack@main"* ]]
    [[ "$output" == *"Commit:       ${SPACK_COMMIT}"* ]]
    [[ "$output" == *"Checksum:     deadbeef"* ]]
    [[ "$output" == *"Imported by:  (the experiment)"* ]]
}

@test "show selects by the knit- prefixed name, the canonical id, and the row id" {
    _seed_two
    run knit plugins show --id knit-spack
    [[ "$output" == *"github.com/knit-sh/knit-spack"* ]]

    run knit plugins show --id github.com/knit-sh/knit-base
    [[ "$output" == *"github.com/knit-sh/knit-base"* ]]

    # The row id printed by one show selects the same row again.
    local rid
    rid="$(knit plugins show --id base | sed -n 's/^Row id:[[:space:]]*//p')"
    [ -n "${rid}" ]
    run knit plugins show --id "${rid}"
    [[ "$output" == *"github.com/knit-sh/knit-base"* ]]
}

@test "show labels an empty ref, checksum, and the importing plugin" {
    _seed_two
    run knit plugins show --id base
    [[ "$output" == *"Ref:          <default branch>"* ]]
    [[ "$output" == *"Checksum:     <none>"* ]]
    [[ "$output" == *"Imported by:  github.com/knit-sh/knit-spack"* ]]
}

@test "show prints one block per recording when a plugin was pinned twice" {
    _seed_import "github.com/knit-sh/knit-spack" "spack@main" "main" \
        "${SPACK_COMMIT}" "deadbeef" ""
    _knit_plugin_bootstrap >/dev/null 2>&1
    # Re-resolve @main to a new commit and record again.
    _KNIT_PLUGIN_COMMITS["github.com/knit-sh/knit-spack"]="${BASE_COMMIT}"
    local dir="${_KNIT_PLUGIN_CACHE_ROOT}/github.com/knit-sh/knit-spack/${BASE_COMMIT}"
    mkdir -p "${dir}"; printf 'body\n' > "${dir}/plugin.sh"
    _knit_plugin_bootstrap >/dev/null 2>&1

    run knit plugins show --id spack
    [ "$status" -eq 0 ]
    local blocks
    blocks="$(printf '%s\n' "$output" | grep -c '^Plugin:')"
    [ "${blocks}" -eq 2 ]
    [[ "$output" == *"${SPACK_COMMIT}"* ]]
    [[ "$output" == *"${BASE_COMMIT}"* ]]
}

@test "show is fatal when no plugin matches" {
    _seed_two
    run knit plugins show --id nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"no plugin matching"* ]]
}

@test "show is fatal when the plugins table does not exist" {
    run knit plugins show --id spack
    [ "$status" -ne 0 ]
    [[ "$output" == *"no plugin matching"* ]]
}
