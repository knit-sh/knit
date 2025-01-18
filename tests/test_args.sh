#!/usr/bin/env bats

setup() {
    source knit.sh
}

@test "finding an option that exists" {
    local args=("--abc" "ABC" "--def" "DEF" "--ghi" "GHI")
    run _knit_find_option "--abc" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "ABC" ]
    run _knit_find_option "--def" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "DEF" ]
    run _knit_find_option "--ghi" "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "GHI" ]
}

@test "finding an option that does not exist" {
    local args=("--abc" "ABC" "--def" "DEF" "--ghi" "GHI")
    run _knit_find_option "--jkl" "${args[@]}"
    [ "$status" -eq 1 ]
}

@test "finding a flag that exists" {
    local args=("--abc" "ABC" "--def" "--ghi" "GHI")
    run _knit_find_flag "--def" "${args[@]}"
    [ "$status" -eq 0 ]
}

@test "finding a flag that does not exist" {
    local args=("--abc" "ABC" "--def" "DEF" "--ghi" "GHI")
    run _knit_find_flag "--jkl" "${args[@]}"
    [ "$status" -eq 1 ]
}

@test "expand --key=value arguments" {
    local args=("--abc" "--def=xyz" "keh")
    run _knit_expand_keyval_args "${args[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "--abc --def xyz keh" ]
}
