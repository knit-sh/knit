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
