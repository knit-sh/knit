#!/usr/bin/env bats

# Feature: hyphens in command names (dispatcher lookup paths). A setup, job, app,
# or resource registered with a hyphen resolves through its dispatcher whether it
# is typed with hyphens or underscores, and is shown with its registered spelling
# in "--help". Identity (registry key, table name, marker) stays canonical
# (underscore).

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    _KNIT_RECORDING_SUPPRESSED=""
}

teardown() {
    knit_test_db_teardown
}

# ---------- registries are keyed by the canonical (underscore) name ----------

@test "knit_register_setup keys the registry by the canonical name" {
    _s_fn() { :; }
    knit_register_setup "libs-inline" "_s_fn" "A setup."
    knit_done
    [[ -v _KNIT_SETUPS["libs_inline"] ]]
    [[ ! -v _KNIT_SETUPS["libs-inline"] ]]
}

@test "knit_register_app keys the registry by the canonical name" {
    _a_fn() { :; }
    knit_register_app "my-app" "_a_fn" "An app."
    knit_done
    [[ -v _KNIT_APPS["my_app"] ]]
    [[ ! -v _KNIT_APPS["my-app"] ]]
}

@test "knit_register_job keys the registry by the canonical name" {
    _j_fn() { :; }
    knit_register_job "my-job" "_j_fn" "A job."
    knit_done
    [[ -v _KNIT_JOBS["my_job"] ]]
    [[ ! -v _KNIT_JOBS["my-job"] ]]
}

@test "knit_register_resource keys the registry by the canonical type" {
    knit_register_resource "my-code" "A resource."
    knit_with_git "https://example.org/x.git" "main"
    knit_done
    [[ -v _KNIT_RESOURCES["my_code"] ]]
    [[ ! -v _KNIT_RESOURCES["my-code"] ]]
}

# ---------- a hyphenated name gives its command a canonical table ----------

@test "a hyphenated app builds a canonical (underscore) table" {
    _a_fn() { :; }
    knit_register_app "my-app" "_a_fn" "An app."
    knit_done
    local under hyphen
    under=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='my_app';")
    hyphen=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='my-app';")
    [ "$under" -eq 1 ]
    [ "$hyphen" -eq 0 ]
}

# ---------- dispatched "--help" resolves either spelling and displays hyphen ----

@test "run <app> --help resolves the underscore spelling and shows the hyphen" {
    _a_fn() { :; }
    knit_register_app "my-app" "_a_fn" "An app."
    knit_done
    local result
    result=$(_knit_invoke_command "run" "my_app" "--help")
    [[ "$result" == *"run [OPTIONS] -- my-app [OPTIONS]"* ]]
}

@test "run <app> --help resolves the hyphen spelling and shows the hyphen" {
    _a_fn() { :; }
    knit_register_app "my-app" "_a_fn" "An app."
    knit_done
    local result
    result=$(_knit_invoke_command "run" "my-app" "--help")
    [[ "$result" == *"run [OPTIONS] -- my-app [OPTIONS]"* ]]
}

@test "submit <job> --help resolves either spelling and shows the hyphen" {
    _j_fn() { :; }
    knit_register_job "my-job" "_j_fn" "A job."
    knit_done
    local result
    result=$(_knit_invoke_command "submit" "my_job" "--help")
    [[ "$result" == *"submit"*"my-job"* ]]
}

# ---------- knit_with_setup marker is canonical (cross-reference) ----------

@test "knit_with_setup stores a canonical marker regardless of spelling" {
    _c_fn() { :; }
    knit_register "consumer" "_c_fn" "A consumer command."
    knit_with_setup "libs-inline"
    knit_done
    local cmd marker
    cmd=$(_knit_command_mangle "consumer")
    marker="_KNIT_CMD_${cmd}_setup"
    [ "${!marker}" = "libs_inline" ]
}

@test "_knit_setup_check_type matches a canonical required type" {
    local dir="${BATS_TEST_TMPDIR}/setupdir"
    mkdir -p "${dir}"
    printf '%s\n' "libs_inline" > "${dir}/.setup.type"
    # The required type (from a canonical knit_with_setup marker) matches the
    # canonical .setup.type recorded by the setup dispatcher.
    _knit_setup_check_type "${dir}" "libs_inline"
}

# ---------- knit_with_resource resolves and stores a canonical marker ----------

@test "knit_with_resource resolves either spelling and stores a canonical marker" {
    knit_register_resource "my-code" "A resource."
    knit_with_git "https://example.org/x.git" "main"
    knit_done

    _c_fn() { :; }
    knit_register "consumer" "_c_fn" "A consumer command."
    # Reference the resource with the underscore spelling; it must resolve to the
    # hyphen-registered type and store a canonical marker.
    knit_with_resource "dep:my_code" "The dependency."
    knit_done

    local cmd marker
    cmd=$(_knit_command_mangle "consumer")
    marker="_KNIT_CMD_${cmd}_resource_dep"
    [ "${!marker}" = "my_code" ]
}
