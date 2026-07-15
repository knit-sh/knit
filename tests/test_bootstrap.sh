#!/usr/bin/env bats

setup() {
    source knit.sh

    # Each test controls _KNIT_PREFIX and _KNIT_IS_BOOTSTRAPPED explicitly.
    # Point _KNIT_PREFIX at a temp path that does not yet exist.
    __TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${__TEST_TMPDIR}/fake-knit"
    _KNIT_IS_BOOTSTRAPPED=""
}

teardown() {
    rm -rf "${__TEST_TMPDIR}"
    _KNIT_IS_BOOTSTRAPPED=""
}

# ---------- _knit_is_bootstrapped ----------

@test "is bootstrapped returns 1 when prefix directory does not exist" {
    run _knit_is_bootstrapped
    [ "$status" -eq 1 ]
}

@test "is bootstrapped returns 0 when prefix directory exists" {
    mkdir "${_KNIT_PREFIX}"
    run _knit_is_bootstrapped
    [ "$status" -eq 0 ]
}

@test "is bootstrapped caches positive result — survives directory deletion" {
    mkdir "${_KNIT_PREFIX}"
    _knit_is_bootstrapped   # populate cache
    rm -rf "${_KNIT_PREFIX}"
    # Directory is gone but cache says bootstrapped — must still return 0
    run _knit_is_bootstrapped
    [ "$status" -eq 0 ]
}

@test "is bootstrapped re-checks filesystem after cache is cleared" {
    mkdir "${_KNIT_PREFIX}"
    _knit_is_bootstrapped           # populate cache
    rm -rf "${_KNIT_PREFIX}"
    _KNIT_IS_BOOTSTRAPPED=""        # clear cache
    run _knit_is_bootstrapped
    [ "$status" -eq 1 ]
}

# ---------- sqlite: symlink vs build decision ----------

# Fake system sqlite3 path handed back by the stubbed _knit_command_path.
__fake_sqlite=""
# Marker created by the stubbed build path.
__sqlite_build_marker=""

# Prepare the prefix and install decision-logic stubs for the sqlite tests.
_setup_sqlite_decision() {
    mkdir "${_KNIT_PREFIX}"
    _KNIT_SQLITE_EXE="${_KNIT_PREFIX}/sqlite/bin/sqlite3"
    __fake_sqlite="${__TEST_TMPDIR}/system-sqlite3"
    printf '#!/bin/sh\n' > "${__fake_sqlite}"
    chmod +x "${__fake_sqlite}"
    __sqlite_build_marker="${__TEST_TMPDIR}/sqlite-built"
    # Stub the from-source build and the framework table creation.
    eval '_knit_build_sqlite() { : > "'"${__sqlite_build_marker}"'"; }'
    eval '_knit_create_metadata_table() { :; }'
    eval '_knit_prov_create_table() { :; }'
}

@test "bootstrap sqlite symlinks the system binary when present and no flag" {
    _setup_sqlite_decision
    _knit_command_path() { printf '%s' "${__fake_sqlite}"; }

    _knit_bootstrap_sqlite

    [ -L "${_KNIT_SQLITE_EXE}" ]
    [ "$(readlink "${_KNIT_SQLITE_EXE}")" = "${__fake_sqlite}" ]
    [ ! -e "${__sqlite_build_marker}" ]
}

@test "bootstrap sqlite builds from source when ignore flag is set" {
    _setup_sqlite_decision
    _knit_command_path() { printf '%s' "${__fake_sqlite}"; }

    _knit_bootstrap_sqlite true

    [ ! -L "${_KNIT_SQLITE_EXE}" ]
    [ -e "${__sqlite_build_marker}" ]
}

@test "bootstrap sqlite builds from source when no system binary present" {
    _setup_sqlite_decision
    _knit_command_path() { printf ''; }

    _knit_bootstrap_sqlite

    [ ! -L "${_KNIT_SQLITE_EXE}" ]
    [ -e "${__sqlite_build_marker}" ]
}

# ---------- jq: symlink vs download decision ----------

__fake_jq=""
__jq_download_marker=""

_setup_jq_decision() {
    mkdir "${_KNIT_PREFIX}"
    _KNIT_JQ_EXE="${_KNIT_PREFIX}/jq/bin/jq"
    __fake_jq="${__TEST_TMPDIR}/system-jq"
    printf '#!/bin/sh\n' > "${__fake_jq}"
    chmod +x "${__fake_jq}"
    __jq_download_marker="${__TEST_TMPDIR}/jq-downloaded"
    eval '_knit_download_jq() { : > "'"${__jq_download_marker}"'"; }'
}

@test "bootstrap jq symlinks the system binary when present and no flag" {
    _setup_jq_decision
    _knit_command_path() { printf '%s' "${__fake_jq}"; }

    _knit_bootstrap_jq

    [ -L "${_KNIT_JQ_EXE}" ]
    [ "$(readlink "${_KNIT_JQ_EXE}")" = "${__fake_jq}" ]
    [ ! -e "${__jq_download_marker}" ]
}

@test "bootstrap jq downloads when ignore flag is set" {
    _setup_jq_decision
    _knit_command_path() { printf '%s' "${__fake_jq}"; }

    _knit_bootstrap_jq true

    [ ! -L "${_KNIT_JQ_EXE}" ]
    [ -e "${__jq_download_marker}" ]
}

@test "bootstrap jq downloads when no system binary present" {
    _setup_jq_decision
    _knit_command_path() { printf ''; }

    _knit_bootstrap_jq

    [ ! -L "${_KNIT_JQ_EXE}" ]
    [ -e "${__jq_download_marker}" ]
}
