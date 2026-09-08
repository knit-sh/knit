#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../knit.sh"
    # Start each test from a clean slate: the array is global and persists
    # across the sourced framework, so reset it explicitly.
    _KNIT_BUNDLE_REQUIRES=()
}

# ---------- knit_bundle_requires ----------

@test "knit_bundle_requires records a single path" {
    knit_bundle_requires "config/params.yaml"
    [ "${#_KNIT_BUNDLE_REQUIRES[@]}" -eq 1 ]
    [ "${_KNIT_BUNDLE_REQUIRES[0]}" = "config/params.yaml" ]
}

@test "knit_bundle_requires accumulates paths in declaration order" {
    knit_bundle_requires "config/params.yaml"
    knit_bundle_requires "inputs/mesh.dat"
    knit_bundle_requires "scripts/plot.py"
    [ "${#_KNIT_BUNDLE_REQUIRES[@]}" -eq 3 ]
    [ "${_KNIT_BUNDLE_REQUIRES[0]}" = "config/params.yaml" ]
    [ "${_KNIT_BUNDLE_REQUIRES[1]}" = "inputs/mesh.dat" ]
    [ "${_KNIT_BUNDLE_REQUIRES[2]}" = "scripts/plot.py" ]
}

@test "knit_bundle_requires stores a relative path verbatim" {
    knit_bundle_requires "a/b/../c.txt"
    [ "${_KNIT_BUNDLE_REQUIRES[0]}" = "a/b/../c.txt" ]
}

@test "knit_bundle_requires stores an absolute path verbatim (no rejection at declaration)" {
    knit_bundle_requires "/etc/hosts"
    [ "${_KNIT_BUNDLE_REQUIRES[0]}" = "/etc/hosts" ]
}

@test "knit_bundle_requires stores a glob pattern verbatim (no expansion at declaration)" {
    knit_bundle_requires "inputs/*.dat"
    [ "${#_KNIT_BUNDLE_REQUIRES[@]}" -eq 1 ]
    [ "${_KNIT_BUNDLE_REQUIRES[0]}" = "inputs/*.dat" ]
}

@test "knit_bundle_requires does not fatal on a missing path at declaration" {
    run knit_bundle_requires "does/not/exist.txt"
    [ "${status}" -eq 0 ]
}

@test "knit_bundle_requires touches nothing on the filesystem at declaration" {
    # A path with glob metacharacters must not be expanded or stat'd here.
    run knit_bundle_requires "/no/such/dir/*"
    [ "${status}" -eq 0 ]
}

# ---------- @bundle_requires shorthand ----------

@test "@bundle_requires forwards to knit_bundle_requires" {
    @bundle_requires "scripts/plot.py"
    [ "${#_KNIT_BUNDLE_REQUIRES[@]}" -eq 1 ]
    [ "${_KNIT_BUNDLE_REQUIRES[0]}" = "scripts/plot.py" ]
}
