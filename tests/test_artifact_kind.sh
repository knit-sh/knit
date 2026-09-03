#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
}

# ---------- builtin kinds ----------

@test "builtin kind file is backed by the file type" {
    local t
    _knit_artifact_kind_type t "file"
    [ "${t}" = "file" ]
}

@test "builtin kind directory is backed by the directory type" {
    local t
    _knit_artifact_kind_type t "directory"
    [ "${t}" = "directory" ]
}

@test "builtin kind alias dir is backed by the directory type" {
    local t
    _knit_artifact_kind_type t "dir"
    [ "${t}" = "directory" ]
}

@test "_knit_artifact_kind_type returns non-zero for an unknown kind" {
    local t="untouched"
    run _knit_artifact_kind_type t "nosuchkind"
    [ "${status}" -ne 0 ]
}

# ---------- knit_register_artifact (happy path) ----------

@test "registering a user kind records its physical type" {
    knit_register_artifact "csvfile:file" "Tabulated result in CSV format."
    local t
    _knit_artifact_kind_type t "csvfile"
    [ "${t}" = "file" ]
}

@test "registering a user kind records its description" {
    knit_register_artifact "csvfile:file" "Tabulated result in CSV format."
    [ "${_KNIT_ARTIFACT_KIND_DESCRIPTIONS[csvfile]}" = "Tabulated result in CSV format." ]
}

@test "a directory-backed kind records the directory type" {
    knit_register_artifact "rundir:directory" "A run's output directory."
    local t
    _knit_artifact_kind_type t "rundir"
    [ "${t}" = "directory" ]
}

@test "a kind backed by the dir alias stores the canonical directory type" {
    knit_register_artifact "rundir:dir" "A run's output directory."
    local t
    _knit_artifact_kind_type t "rundir"
    [ "${t}" = "directory" ]
}

@test "the description is optional" {
    knit_register_artifact "csvfile:file"
    local t
    _knit_artifact_kind_type t "csvfile"
    [ "${t}" = "file" ]
}

# ---------- knit_register_artifact (fatal paths) ----------

@test "a missing type annotation is fatal" {
    run knit_register_artifact "csvfile" "No type."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"missing a type annotation"* ]]
}

@test "an invalid kind name is fatal" {
    run knit_register_artifact "-bad:file" "Bad name."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not a valid name"* ]]
}

@test "an unknown physical type is fatal" {
    run knit_register_artifact "csvfile:bogus" "Bad type."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unknown type"* ]]
}

@test "a non-checksummable physical type is fatal" {
    run knit_register_artifact "csvfile:integer" "Wrong type."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"must be backed by type"* ]]
}

@test "a string-backed kind is fatal (not checksummable)" {
    run knit_register_artifact "csvfile:string" "Wrong type."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"must be backed by type"* ]]
}

@test "re-registering a user kind is fatal" {
    knit_register_artifact "csvfile:file" "First."
    run knit_register_artifact "csvfile:file" "Second."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"already registered"* ]]
}

@test "re-registering the builtin kind file is fatal" {
    run knit_register_artifact "file:file" "Reserved."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"already registered"* ]]
}

@test "re-registering the builtin kind directory is fatal" {
    run knit_register_artifact "directory:directory" "Reserved."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"already registered"* ]]
}

@test "re-registering the builtin alias dir is fatal" {
    run knit_register_artifact "dir:directory" "Reserved."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"already registered"* ]]
}

# ---------- @artifact shorthand ----------

@test "the @artifact shorthand registers a kind" {
    @artifact "csvfile:file" "Tabulated result in CSV format."
    local t
    _knit_artifact_kind_type t "csvfile"
    [ "${t}" = "file" ]
}

@test "the @artifact shorthand forwards fatal errors" {
    run @artifact "csvfile:bogus" "Bad type."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unknown type"* ]]
}
