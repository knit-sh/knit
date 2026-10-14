#!/usr/bin/env bats

# Tests for the plugin bootstrap integration (src/plugin.sh, M9): the plugins
# provenance table, row recording, the committed lockfile write, tree
# materialization under .knit, the "knit plugins lock" command, and the
# importer (dependency) edge recorded through the import stack. The network seam
# is stubbed so the file is offline and deterministic.

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_require_sqlite
    knit_test_db_setup

    __TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${__TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    _KNIT_PLUGIN_CACHE_ROOT="${__TEST_TMPDIR}/cache"
    _KNIT_PLUGIN_LOCKFILE="${__TEST_TMPDIR}/knit-plugins.lock"
    MARKER="${__TEST_TMPDIR}/sourced.log"
    : > "${MARKER}"
    unset KNIT_OFFLINE

    # Start from a clean in-memory import state.
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

COMMIT="0123456789abcdef0123456789abcdef01234567"

# Record a single imported plugin in the in-memory order set and seed its cache
# tree, so _knit_plugin_bootstrap has something to record and materialize.
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
    printf 'plugin body\n' > "${dir}/plugin.sh"
}

# ---------- table creation ----------

@test "ensure_table creates the plugins table with the declared columns" {
    _knit_plugin_ensure_table
    local cols
    cols="$(_knit_sqlite3 \
        "SELECT name FROM pragma_table_info('plugins') ORDER BY name;")"
    [[ "${cols}" == *"checksum"* ]]
    [[ "${cols}" == *"commit"* ]]
    [[ "${cols}" == *"imported_by"* ]]
    [[ "${cols}" == *"installed_at"* ]]
    [[ "${cols}" == *"spec"* ]]
}

@test "ensure_table runs the create at most once per process" {
    _knit_plugin_ensure_table
    # A second call must not attempt to re-create the table (which would fatal).
    _knit_db_create_table() { echo "SHOULD_NOT_BE_CALLED"; return 1; }
    run _knit_plugin_ensure_table
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------- row recording ----------

@test "bootstrap records a provenance row with the resolved pin" {
    _seed_import "github.com/knit-sh/knit-demo" "demo@main" "main" \
        "${COMMIT}" "sum123" ""
    _knit_plugin_bootstrap
    local row
    row="$(_knit_sqlite3 \
        "SELECT host||'|'||org||'|'||repo||'|'||ref||'|'||\"commit\"||'|'||checksum \
         FROM plugins;")"
    [ "${row}" = "github.com|knit-sh|knit-demo|main|${COMMIT}|sum123" ]
}

@test "bootstrap assigns each recorded plugin a non-empty uuid row id" {
    _seed_import "github.com/knit-sh/knit-demo" "demo" "" "${COMMIT}" "" ""
    _knit_plugin_bootstrap
    local id
    id="$(_knit_sqlite3 "SELECT id FROM plugins;")"
    [ -n "${id}" ]
}

@test "recording is idempotent across repeated bootstraps" {
    _seed_import "github.com/knit-sh/knit-demo" "demo@main" "main" \
        "${COMMIT}" "sum123" ""
    _knit_plugin_bootstrap
    _knit_plugin_bootstrap
    local count
    count="$(_knit_sqlite3 "SELECT COUNT(*) FROM plugins;")"
    [ "${count}" -eq 1 ]
}

@test "a changed commit for the same repo records a second row" {
    _seed_import "github.com/knit-sh/knit-demo" "demo@main" "main" \
        "${COMMIT}" "sum123" ""
    _knit_plugin_bootstrap
    # Re-resolve @main to a new commit, then bootstrap again.
    _KNIT_PLUGIN_COMMITS["github.com/knit-sh/knit-demo"]="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    mkdir -p "${_KNIT_PLUGIN_CACHE_ROOT}/github.com/knit-sh/knit-demo/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    printf 'body\n' > "${_KNIT_PLUGIN_CACHE_ROOT}/github.com/knit-sh/knit-demo/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/plugin.sh"
    _knit_plugin_bootstrap
    local count
    count="$(_knit_sqlite3 "SELECT COUNT(*) FROM plugins;")"
    [ "${count}" -eq 2 ]
}

# ---------- lockfile write ----------

@test "bootstrap writes every imported pin to the lockfile" {
    _seed_import "github.com/knit-sh/knit-demo" "demo@main" "main" \
        "${COMMIT}" "sum123" ""
    _knit_plugin_bootstrap
    local c s
    _knit_plugin_lock_get c s "github.com/knit-sh/knit-demo"
    [ "${c}" = "${COMMIT}" ]
    [ "${s}" = "sum123" ]
}

# ---------- materialization ----------

@test "bootstrap materializes the pinned tree under .knit/plugins" {
    _seed_import "github.com/knit-sh/knit-demo" "demo@main" "main" \
        "${COMMIT}" "sum123" ""
    _knit_plugin_bootstrap
    [ -f "${_KNIT_PREFIX}/plugins/github.com/knit-sh/knit-demo/plugin.sh" ]
}

@test "materialization is a no-op when the cache tree is absent" {
    # An id in the order set with no seeded cache tree (e.g. deferred offline).
    _KNIT_PLUGIN_ORDER+=("github.com/knit-sh/knit-gone")
    _KNIT_PLUGIN_COMMITS["github.com/knit-sh/knit-gone"]="${COMMIT}"
    _knit_plugin_materialize "github.com/knit-sh/knit-gone"
    [ ! -e "${_KNIT_PREFIX}/plugins/github.com/knit-sh/knit-gone" ]
}

# ---------- knit plugins lock ----------

@test "knit plugins lock reports nothing to lock with no imports" {
    run knit plugins lock
    [ "$status" -eq 0 ]
    [ ! -f "${_KNIT_PLUGIN_LOCKFILE}" ]
}

@test "plugins lock writes the lockfile without touching the database" {
    _seed_import "github.com/knit-sh/knit-demo" "demo@main" "main" \
        "${COMMIT}" "sum123" ""
    _knit_plugins_lock
    [ -f "${_KNIT_PLUGIN_LOCKFILE}" ]
    # No plugins table was created (lock does not touch the DB).
    local exists
    exists="$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='plugins';")"
    [ "${exists}" -eq 0 ]
}

# ---------- importer (dependency) edge via the import stack ----------

@test "a transitive import records the importing plugin as imported_by" {
    _knit_github_resolve_commit_light() {
        # $1=out $2=org $3=repo $4=ref -> a deterministic per-repo commit.
        local -n __o=$1; __o="commit_$3"
    }
    knit_github_download() {
        local -n __out=$1; shift
        local repo="$2" dest="$3"
        if [[ "${repo}" == "knit-parent" ]]; then
            # The parent's plugin.sh imports its child dependency.
            printf 'knit_import "child"\n' > "${dest}/plugin.sh"
        else
            printf 'printf done >> %q\n' "${MARKER}" > "${dest}/plugin.sh"
        fi
        __out="sum_${repo}"
    }

    knit_import "parent"

    # Both were imported, parent before child.
    [ "${#_KNIT_PLUGIN_ORDER[@]}" -eq 2 ]
    [ "${_KNIT_PLUGIN_ORDER[0]}" = "github.com/knit-sh/knit-parent" ]
    [ "${_KNIT_PLUGIN_ORDER[1]}" = "github.com/knit-sh/knit-child" ]
    # The experiment imported the parent; the parent imported the child.
    [ "${_KNIT_PLUGIN_IMPORTED_BY[github.com/knit-sh/knit-parent]}" = "" ]
    [ "${_KNIT_PLUGIN_IMPORTED_BY[github.com/knit-sh/knit-child]}" = "github.com/knit-sh/knit-parent" ]
    # The stack is balanced again after sourcing.
    [ "${#_KNIT_PLUGIN_IMPORT_STACK[@]}" -eq 0 ]
}
