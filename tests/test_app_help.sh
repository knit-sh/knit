#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# The `run` dispatcher reuses the existing dispatcher --help renderer (the same
# one `submit` uses): `run <app> --help` prints the real grammar
# (`run [OPTIONS] -- <app> [OPTIONS]`), the app's own options, and a borrowed
# block of the parent `run` placement options. Apps have no setup, so there is
# never a Requirements section.

# ---------- run <app> --help ----------

@test "run <app> --help uses the dispatcher grammar and shows the app options" {
    _test_app_fn() { :; }
    knit_register_app "myapp" "_test_app_fn" "A test app."
    knit_with_optional "n:integer" "100" "Problem size."
    knit_with_flag "greet" "Print a greeting."
    knit_done

    local result
    result=$(_knit_invoke_command "run" "myapp" "--help")
    [[ "$result" == *"run [OPTIONS] -- myapp [OPTIONS]"* ]]
    [[ "$result" == *"--n"* ]]
    [[ "$result" == *"--greet"* ]]
}

@test "run <app> --help shows the placement options in a borrowed run block" {
    _test_app_fn() { :; }
    knit_register_app "myapp" "_test_app_fn" "A test app."
    knit_done

    local result
    result=$(_knit_invoke_command "run" "myapp" "--help")
    [[ "$result" == *"run options"* ]]
    [[ "$result" == *"--procs"* ]]
    [[ "$result" == *"--procs-per-node"* ]]
    [[ "$result" == *"--hostnames"* ]]
    [[ "$result" == *"--launcher"* ]]
    [[ "$result" == *"--launcher-args"* ]]
    [[ "$result" == *"--cpus-per-proc"* ]]
    [[ "$result" == *"--bind"* ]]
    [[ "$result" == *"--gpus-per-proc"* ]]
    [[ "$result" == *"--gpu-bind"* ]]
}

@test "run <app> --help has no Requirements section (apps have no setup)" {
    _test_app_fn() { :; }
    knit_register_app "myapp" "_test_app_fn" "A test app."
    knit_done

    local result
    result=$(_knit_invoke_command "run" "myapp" "--help")
    [[ "$result" != *"Requirements"* ]]
    [[ "$result" != *"--setup"* ]]
}

# ---------- run --help (the dispatcher itself) ----------

@test "run --help lists registered apps under the Apps title" {
    _test_app_fn() { :; }
    knit_register_app "myapp" "_test_app_fn" "A test app."
    knit_done

    local result
    result=$(_knit_invoke_command "run" "--help")
    [[ "$result" == *"run [OPTIONS] -- <app> [OPTIONS]"* ]]
    [[ "$result" == *"Apps"* ]]
    [[ "$result" == *"myapp"* ]]
}
