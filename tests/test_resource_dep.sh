#!/usr/bin/env bats

# Tests for knit_with_resource (M6): the "<param>:<type>" declaration (registry
# check, underlying required parameter, per-param marker) and the validation
# before-callback (_knit_resource_dep_before_cb) — instance missing, type
# mismatch, and the success path. No downloading: instances are faked on disk
# with their .resource.type sidecar so validation runs without a real fetch.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _knit_create_metadata_table

    # Experiment root = the directory containing .knit; resources default to
    # <root>/resources.
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    _RES_ROOT="${_KNIT_TEST_TMPDIR}/resources"
    mkdir -p "${_RES_ROOT}"

    # A resource type "images" so knit_with_resource has something to reference.
    knit_register_resource "images" "An image dataset."
    knit_with_url "https://example.org/x.tar.gz"
    knit_done
}

teardown() {
    if [[ -n "${_KNIT_TEST_TMPDIR:-}" && -e "${_KNIT_TEST_TMPDIR}" ]]; then
        chmod -R u+w "${_KNIT_TEST_TMPDIR}" 2>/dev/null || true
        rm -rf "${_KNIT_TEST_TMPDIR}"
    fi
    knit_test_db_teardown
}

# Fake a fetched instance named <name> of type <type> (a directory plus its
# .resource.type sidecar), so the before-callback validates it as fetched.
_fake_instance() {
    local name="$1" type="$2"
    mkdir -p "${_RES_ROOT}/${name}"
    printf '%s\n' "${type}" > "${_RES_ROOT}/.${name}.resource.type"
}

# ---------- declaration ----------

@test "declares a required parameter for the resource" {
    knit_register "train" _train "Train."
    knit_with_resource "training_dataset:images" "Training images."
    _train() { :; }
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "train")
    _knit_set_find "_KNIT_CMD_${cmd}_required" "training_dataset"
}

@test "records the per-parameter resource type marker" {
    knit_register "train" _train "Train."
    knit_with_resource "training_dataset:images" "Training images."
    _train() { :; }
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "train")
    local marker="_KNIT_CMD_${cmd}_resource_training_dataset"
    [ "${!marker}" = "images" ]
}

@test "normalizes a hyphenated parameter name in the marker" {
    knit_register "train" _train "Train."
    knit_with_resource "training-set:images" "Images."
    _train() { :; }
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "train")
    local marker="_KNIT_CMD_${cmd}_resource_training_set"
    [ "${!marker}" = "images" ]
}

@test "rejects an unknown resource type" {
    knit_register "train" _train "Train."
    run knit_with_resource "d:nope" "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown resource type"* ]]
    _train() { :; }
}

@test "rejects an annotation without a colon" {
    knit_register "train" _train "Train."
    run knit_with_resource "dataset" "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"<param>:<type>"* ]]
    _train() { :; }
}

@test "rejects an empty resource type after the colon" {
    knit_register "train" _train "Train."
    run knit_with_resource "dataset:" "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"resource type after the colon"* ]]
    _train() { :; }
}

@test "outside a registration is fatal" {
    run knit_with_resource "d:images" "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"between a knit_register"* ]]
}

@test "a wrapper cannot declare a resource" {
    knit_register_wrapper "wrap" _wrap "A wrapper."
    run knit_with_resource "d:images" "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"wrapper"* ]]
    _wrap() { :; }
}

@test "a command may declare several resources" {
    knit_register "train" _train "Train."
    knit_with_resource "train_set:images" "Training images."
    knit_with_resource "test_set:images" "Testing images."
    _train() { :; }
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "train")
    _knit_set_find "_KNIT_CMD_${cmd}_required" "train_set"
    _knit_set_find "_KNIT_CMD_${cmd}_required" "test_set"
}

# ---------- validation before-callback ----------

@test "validation passes for a fetched instance of the right type" {
    _fake_instance "cats" "images"
    knit_register "train" _train "Train."
    knit_with_resource "dataset:images" "Images."
    _train() { printf 'ran\n'; }
    knit_done
    run _knit_invoke_command "train" --dataset cats
    [ "$status" -eq 0 ]
    [[ "$output" == *"ran"* ]]
}

@test "validation fatals when the instance is not fetched" {
    knit_register "train" _train "Train."
    knit_with_resource "dataset:images" "Images."
    _train() { printf 'ran\n'; }
    knit_done
    run _knit_invoke_command "train" --dataset missing
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not fetched"* ]]
    [[ "$output" == *"fetch --name missing -- images"* ]]
    [[ "$output" != *"ran"* ]]
}

@test "validation fatals on a type mismatch" {
    _fake_instance "cats" "other_type"
    knit_register "train" _train "Train."
    knit_with_resource "dataset:images" "Images."
    _train() { printf 'ran\n'; }
    knit_done
    run _knit_invoke_command "train" --dataset cats
    [ "$status" -ne 0 ]
    [[ "$output" == *"is of type \"other_type\""* ]]
    [[ "$output" == *"\"images\" resource is required"* ]]
    [[ "$output" != *"ran"* ]]
}

@test "validation fatals when the type sidecar is missing" {
    mkdir -p "${_RES_ROOT}/cats"   # instance dir, but no .resource.type sidecar
    knit_register "train" _train "Train."
    knit_with_resource "dataset:images" "Images."
    _train() { printf 'ran\n'; }
    knit_done
    run _knit_invoke_command "train" --dataset cats
    [ "$status" -ne 0 ]
    [[ "$output" == *"<unknown>"* ]]
    [[ "$output" != *"ran"* ]]
}

@test "validation fatals when the resource name is empty" {
    knit_register "train" _train "Train."
    knit_with_resource "dataset:images" "Images."
    _train() { printf 'ran\n'; }
    knit_done
    run _knit_resource_dep_before_cb "dataset" "images" --dataset ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a resource of type \"images\""* ]]
    [[ "$output" == *"--dataset"* ]]
}

@test "validation accepts a symlinked local instance" {
    local target="${_KNIT_TEST_TMPDIR}/staged"
    mkdir -p "${target}"
    ln -s "${target}" "${_RES_ROOT}/staged_set"
    printf '%s\n' "images" > "${_RES_ROOT}/.staged_set.resource.type"
    run _knit_resource_dep_before_cb "dataset" "images" --dataset staged_set
    [ "$status" -eq 0 ]
}
