#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # Start each test from a clean slate: the array is global and persists
    # across the sourced framework, so reset it explicitly.
    _KNIT_BUNDLE_REQUIRES=()

    # Build a throwaway experiment tree: a root directory holding .knit/knit.db,
    # the experiment script, and the knit.sh framework beside it. The root is
    # derived from _KNIT_PREFIX by the framework (the directory that holds .knit),
    # so pointing _KNIT_PREFIX at this tree makes every resolver agree.
    BUNDLE_ROOT="$(mktemp -d)"
    mkdir -p "${BUNDLE_ROOT}/.knit"
    _KNIT_PREFIX="${BUNDLE_ROOT}/.knit"
    _KNIT_DATABASE="${_KNIT_PREFIX}/knit.db"
    _KNIT_SQLITE_EXE="sqlite3"
    _KNIT_IS_BOOTSTRAPPED="1"
    KNIT_SCRIPT_PATH="${BUNDLE_ROOT}/experiment.sh"
    KNIT_SCRIPT_NAME="experiment.sh"
    printf '#!/bin/bash\nsource knit.sh\n' > "${BUNDLE_ROOT}/experiment.sh"
    printf '# knit framework (test stub)\n'  > "${BUNDLE_ROOT}/knit.sh"
    _knit_create_metadata_table
}

teardown() {
    rm -rf "${BUNDLE_ROOT}"
    knit_test_db_teardown
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

# ---------- default output path ----------

@test "default output falls back to the script name without .sh" {
    local out
    _knit_bundle_default_output out tar
    [ "${out}" = "./experiment-bundle.tar.gz" ]
}

@test "default output uses the project name from metadata" {
    _knit_sqlite3_write \
        "INSERT INTO metadata (key, value) VALUES ('__project__', 'montecarlo-pi');"
    local out
    _knit_bundle_default_output out tar
    [ "${out}" = "./montecarlo-pi-bundle.tar.gz" ]
}

@test "default output uses a .zip extension for the zip format" {
    local out
    _knit_bundle_default_output out zip
    [ "${out}" = "./experiment-bundle.zip" ]
}

# ---------- archive contents ----------

@test "bundle produces a tar.gz containing the script, knit.sh, and knit.db" {
    local out="${BUNDLE_ROOT}/out.tar.gz"
    run _knit_bundle --output "${out}"
    [ "${status}" -eq 0 ]
    [ -f "${out}" ]
    run tar -tzf "${out}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"experiment.sh"* ]]
    [[ "${output}" == *"knit.sh"* ]]
    [[ "${output}" == *".knit/knit.db"* ]]
}

@test "bundle unpacks to paths relative to the archive root" {
    local out="${BUNDLE_ROOT}/out.tar.gz"
    _knit_bundle --output "${out}"
    local dest; dest="$(mktemp -d)"
    tar -xzf "${out}" -C "${dest}"
    [ -f "${dest}/experiment.sh" ]
    [ -f "${dest}/knit.sh" ]
    [ -f "${dest}/.knit/knit.db" ]
    rm -rf "${dest}"
}

@test "bundle includes a declared required file" {
    mkdir -p "${BUNDLE_ROOT}/config"
    printf 'a: 1\n' > "${BUNDLE_ROOT}/config/params.yaml"
    knit_bundle_requires "config/params.yaml"
    local out="${BUNDLE_ROOT}/out.tar.gz"
    _knit_bundle --output "${out}"
    run tar -tzf "${out}"
    [[ "${output}" == *"config/params.yaml"* ]]
}

@test "bundle skips a missing required file with a warning, without failing" {
    knit_bundle_requires "config/absent.yaml"
    local out="${BUNDLE_ROOT}/out.tar.gz"
    run _knit_bundle --output "${out}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"absent.yaml"* ]]
    run tar -tzf "${out}"
    [[ "${output}" != *"absent.yaml"* ]]
}

@test "bundle --zip yields a zip archive" {
    if ! command -v zip &>/dev/null; then skip "zip not available"; fi
    local out="${BUNDLE_ROOT}/out.zip"
    run _knit_bundle --output "${out}" --zip true
    [ "${status}" -eq 0 ]
    [ -f "${out}" ]
    run unzip -l "${out}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"experiment.sh"* ]]
    [[ "${output}" == *"knit.sh"* ]]
}

# ---------- symlink dereferencing ----------

@test "bundle dereferences a symlink to a file outside the tree" {
    # A result file lives outside the experiment tree and is linked back in, as
    # on HPC where results sit on a parallel filesystem.
    local ext; ext="$(mktemp -d)"
    printf 'real content\n' > "${ext}/result.txt"
    ln -s "${ext}/result.txt" "${BUNDLE_ROOT}/result.txt"
    knit_bundle_requires "result.txt"

    local out="${BUNDLE_ROOT}/out.tar.gz"
    _knit_bundle --output "${out}"

    local dest; dest="$(mktemp -d)"
    tar -xzf "${out}" -C "${dest}"
    # The extracted entry is a real file (the link was dereferenced), not a link,
    # and it carries the target's content.
    [ -f "${dest}/result.txt" ]
    [ ! -L "${dest}/result.txt" ]
    run cat "${dest}/result.txt"
    [ "${output}" = "real content" ]

    rm -rf "${ext}" "${dest}"
}

@test "bundle skips a dangling symlink with a warning" {
    ln -s "/no/such/target" "${BUNDLE_ROOT}/dangling.txt"
    knit_bundle_requires "dangling.txt"
    local out="${BUNDLE_ROOT}/out.tar.gz"
    run _knit_bundle --output "${out}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dangling.txt"* ]]
    run tar -tzf "${out}"
    [[ "${output}" != *"dangling.txt"* ]]
}
