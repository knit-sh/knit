#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Tests for the plugin lockfile, deferral, the command_not_found safety net, and
# the describe/--help deferred footer (src/plugin.sh, M8). The network seam is
# stubbed so the file is offline and deterministic.

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit

    __TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PLUGIN_CACHE_ROOT="${__TEST_TMPDIR}/cache"
    _KNIT_PLUGIN_LOCKFILE="${__TEST_TMPDIR}/knit-plugins.lock"
    MARKER="${__TEST_TMPDIR}/sourced.log"
    : > "${MARKER}"
    unset KNIT_OFFLINE
    _KNIT_PLUGIN_DEFERRED=()
    _KNIT_PLUGIN_CNF_INSTALLED="false"
}

teardown() {
    rm -rf "${__TEST_TMPDIR}"
}

SHA="0123456789abcdef0123456789abcdef01234567"

_seed_cache() {
    local host="$1" org="$2" repo="$3" commit="$4" tag="$5"
    local dir="${_KNIT_PLUGIN_CACHE_ROOT}/${host}/${org}/${repo}/${commit}"
    mkdir -p "${dir}"
    printf 'printf "%%s\\n" %q >> %q\n' "${tag}" "${MARKER}" > "${dir}/plugin.sh"
}

# ---------- lockfile round-trip ----------

@test "lock_set then lock_get round-trips a pin with checksum" {
    _knit_plugin_lock_set "github.com/knit-sh/knit-demo" "${SHA}" "sum123"
    local c s
    _knit_plugin_lock_get c s "github.com/knit-sh/knit-demo"
    [ "${c}" = "${SHA}" ]
    [ "${s}" = "sum123" ]
}

@test "lock_set round-trips a pin without a checksum" {
    _knit_plugin_lock_set "github.com/a/b" "commitonly" ""
    local c s
    _knit_plugin_lock_get c s "github.com/a/b"
    [ "${c}" = "commitonly" ]
    [ "${s}" = "" ]
}

@test "lock_get returns non-zero for an absent id" {
    _knit_plugin_lock_set "github.com/a/b" "x" ""
    local c s
    run _knit_plugin_lock_get c s "github.com/other/thing"
    [ "$status" -eq 1 ]
}

@test "lock_set keeps existing entries and sorts by id" {
    _knit_plugin_lock_set "github.com/z/z" "zc" ""
    _knit_plugin_lock_set "github.com/a/a" "ac" ""
    # Both survive.
    local c s
    _knit_plugin_lock_get c s "github.com/z/z"
    [ "${c}" = "zc" ]
    _knit_plugin_lock_get c s "github.com/a/a"
    [ "${c}" = "ac" ]
    # Entries are sorted (a before z), after the comment header.
    local first
    first="$(grep -v '^#' "${_KNIT_PLUGIN_LOCKFILE}" | head -1)"
    [[ "${first}" == "github.com/a/a "* ]]
}

# ---------- resolution precedence: lockfile pin wins ----------

@test "resolve_commit prefers a lockfile pin over resolving the ref" {
    _knit_plugin_lock_set "github.com/knit-sh/knit-demo" "pinnedcommit" "s"
    _knit_github_resolve_commit_light() { local -n __o=$1; __o="SHOULD_NOT_BE_CALLED"; }
    local c wb
    _knit_plugin_resolve_commit c wb "github.com" "knit-sh" "knit-demo" "main"
    [ "${c}" = "pinnedcommit" ]
    # A pin is authoritative, so nothing is written back.
    [ "${wb}" = "false" ]
}

@test "a lockfile pin lets a mutable ref resolve offline" {
    _knit_plugin_lock_set "github.com/knit-sh/knit-demo" "${SHA}" "s"
    _seed_cache "github.com" "knit-sh" "knit-demo" "${SHA}" "PINNED"
    KNIT_OFFLINE=1
    knit_import "demo@main"
    [ "$(cat "${MARKER}")" = "PINNED" ]
}

# ---------- write-back of a freshly resolved mutable ref ----------

@test "knit_import writes a resolved mutable ref back to the lockfile" {
    _knit_github_resolve_commit_light() { local -n __o=$1; __o="${SHA}"; }
    _knit_github_download() {
        local -n __out=$1; shift
        mkdir -p "$4"
        printf 'printf "%%s\\n" TOFU >> %q\n' "${MARKER}" > "$4/plugin.sh"
        __out="fetchsum"
    }
    knit_import "demo@main"
    local c s
    _knit_plugin_lock_get c s "github.com/knit-sh/knit-demo"
    [ "${c}" = "${SHA}" ]
    # The fetched checksum is recorded alongside the commit.
    [ "${s}" = "fetchsum" ]
}

@test "a SHA-pinned import does not write the lockfile" {
    _knit_github_download() {
        local -n __out=$1; shift
        mkdir -p "$4"
        printf 'printf "%%s\\n" X >> %q\n' "${MARKER}" > "$4/plugin.sh"
        __out="s"
    }
    knit_import "demo@${SHA}"
    [ ! -f "${_KNIT_PLUGIN_LOCKFILE}" ]
}

# ---------- deferral + command_not_found net ----------

@test "deferring installs the command_not_found net and records the plugin" {
    KNIT_OFFLINE=1
    knit_import "demo@main"
    [ "${#_KNIT_PLUGIN_DEFERRED[@]}" -eq 1 ]
    [ "${_KNIT_PLUGIN_DEFERRED[0]}" = "github.com/knit-sh/knit-demo@main" ]
    [ "${_KNIT_PLUGIN_CNF_INSTALLED}" = "true" ]
}

@test "the command_not_found net treats a missing knit_/@ symbol as a no-op" {
    _knit_plugin_install_cnf_net
    # A missing knit_* symbol returns 0 (so a "set -e" source survives).
    run knit_this_symbol_does_not_exist --flag
    [ "$status" -eq 0 ]
    # A missing @ shorthand likewise.
    run @no_such_decorator foo
    [ "$status" -eq 0 ]
}

@test "the command_not_found net still fails an unrelated missing command" {
    _knit_plugin_install_cnf_net
    run -127 definitely_not_a_real_command_xyz
    [[ "$output" == *"command not found"* ]]
}

# ---------- deferred footer ----------

@test "the footer lists deferred plugins on stderr and is silent when none" {
    # Silent with an empty list.
    run _knit_plugin_print_deferred_footer
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # Lists the deferred plugins otherwise.
    _KNIT_PLUGIN_DEFERRED=("github.com/knit-sh/knit-spack@main" "github.com/knit-sh/knit-plot@main")
    run _knit_plugin_print_deferred_footer
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 imported plugins are not available offline"* ]]
    [[ "$output" == *"knit-sh/knit-spack@main"* ]]
    [[ "$output" == *"knit-sh/knit-plot@main"* ]]
}

@test "the footer uses singular wording for one deferred plugin" {
    _KNIT_PLUGIN_DEFERRED=("github.com/knit-sh/knit-spack@main")
    run _knit_plugin_print_deferred_footer
    [[ "$output" == *"1 imported plugin is not available offline"* ]]
}

@test "describe prints the deferred footer after its output" {
    knit_test_require_sqlite
    _KNIT_PLUGIN_DEFERRED=("github.com/knit-sh/knit-spack@main")
    run knit describe --format json
    [ "$status" -eq 0 ]
    [[ "$output" == *"not available offline"* ]]
    [[ "$output" == *"knit-sh/knit-spack@main"* ]]
}
