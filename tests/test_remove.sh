#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup
    # The selector --when constraints are evaluated with jq.
    _KNIT_JQ_EXE="jq"
}

teardown() {
    knit_test_db_teardown
}

# ---------- command surface: describe ----------

@test "describe lists the remove group and every subcommand" {
    run knit describe --format json --only remove --recursive
    [ "$status" -eq 0 ]
    [[ "${output}" == *'"name": "remove"'* ]]
    local sub
    for sub in setup resource job run app command artifact; do
        [[ "${output}" == *"\"name\": \"${sub}\""* ]] || {
            echo "missing subcommand: ${sub}"; false
        }
    done
}

# ---------- command surface: --help renders ----------

@test "remove <subcommand> --help renders for every subcommand" {
    local sub
    for sub in setup resource job run app command artifact; do
        run _knit_invoke_command "remove" "${sub}" "--help"
        [ "$status" -eq 0 ]
        [[ "${output}" == *"Usage:"* ]]
        [[ "${output}" == *"--id"* ]]
        [[ "${output}" == *"--yes"* ]]
        [[ "${output}" == *"--dry-run"* ]]
        [[ "${output}" == *"--keep-files"* ]]
        [[ "${output}" == *"--from-root"* ]]
    done
}

@test "remove setup --help shows the id/name/type selectors" {
    run _knit_invoke_command "remove" "setup" "--help"
    [ "$status" -eq 0 ]
    [[ "${output}" == *"--id"* ]]
    [[ "${output}" == *"--name"* ]]
    [[ "${output}" == *"--type"* ]]
}

@test "remove job --help shows the group selector" {
    run _knit_invoke_command "remove" "job" "--help"
    [ "$status" -eq 0 ]
    [[ "${output}" == *"--group"* ]]
}

@test "remove artifact --help shows --path instead of --name" {
    run _knit_invoke_command "remove" "artifact" "--help"
    [ "$status" -eq 0 ]
    [[ "${output}" == *"--path"* ]]
    [[ "${output}" != *"--name"* ]]
}

# ---------- exactly-one-selector: mutual exclusion via --when ----------

@test "two selectors are fatal (--id and --name)" {
    run _knit_invoke_command "remove" "setup" "--id" "A" "--name" "B"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"must not be provided"* ]]
}

@test "two selectors are fatal (--name and --type)" {
    run _knit_invoke_command "remove" "resource" "--name" "A" "--type" "B"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"must not be provided"* ]]
}

@test "two selectors are fatal on remove job (--group and --id)" {
    run _knit_invoke_command "remove" "job" "--group" "g" "--id" "A"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"must not be provided"* ]]
}

@test "two selectors are fatal on remove artifact (--path and --id)" {
    run _knit_invoke_command "remove" "artifact" "--path" "p" "--id" "A"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"must not be provided"* ]]
}

# ---------- exactly-one-selector: presence via the body check ----------

@test "no selector is fatal (body check)" {
    run _knit_invoke_command "remove" "setup"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"exactly one selector is required"* ]]
}

@test "no selector is fatal on remove artifact (body check)" {
    run _knit_invoke_command "remove" "artifact"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"exactly one selector is required"* ]]
}

# ---------- a single selector passes the contract, reaches the stub ----------

@test "one selector passes the contract and hits the not-implemented stub" {
    run _knit_invoke_command "remove" "setup" "--id" "A"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"not yet implemented"* ]]
}

@test "remove job --group passes the contract and reaches the stub" {
    run _knit_invoke_command "remove" "job" "--group" "g"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"not yet implemented"* ]]
}

@test "remove artifact --path passes the contract and reaches the stub" {
    run _knit_invoke_command "remove" "artifact" "--path" "frame.png"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"not yet implemented"* ]]
}

# ---------- the shared helpers in isolation ----------

@test "_knit_remove_require_one_selector accepts exactly one selector" {
    run _knit_remove_require_one_selector id name type -- --id "A"
    [ "$status" -eq 0 ]
}

@test "_knit_remove_require_one_selector refuses zero selectors" {
    run _knit_remove_require_one_selector id name type --
    [ "$status" -ne 0 ]
    [[ "${output}" == *"exactly one selector is required"* ]]
}
