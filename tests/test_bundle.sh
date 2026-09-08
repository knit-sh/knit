#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # Start each test from a clean slate: the arrays are global and persist
    # across the sourced framework, so reset them explicitly.
    _KNIT_BUNDLE_REQUIRES=()
    _KNIT_BUNDLE_AUTO_REQUIRES=()

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

@test "bundle fatals on a missing required file, naming it" {
    # A user-declared required file that does not exist is a clear error (M5),
    # unlike the framework-enumerated optional paths, which are skipped silently.
    knit_bundle_requires "config/absent.yaml"
    local out="${BUNDLE_ROOT}/out.tar.gz"
    run _knit_bundle --output "${out}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"config/absent.yaml"* ]]
    [ ! -e "${out}" ]
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

# ---------- default inventory, filters, and pruned .knit (M3) ----------

# Return 0 if the first argument appears among the remaining arguments.
_collect_has() {
    local needle="$1"; shift
    local e
    for e in "$@"; do [[ "${e}" == "${needle}" ]] && return 0; done
    return 1
}

# Build a full experiment tree under BUNDLE_ROOT: a Spack setup (with a built
# spack-env that must be pruned), one job directory (logs, scripts, submit
# metadata, and user content), an artifact, a fetched resource with its sidecar
# marker, and the provisioned tools under .knit that must never be packed.
_populate_tree() {
    mkdir -p "${BUNDLE_ROOT}/setups/mclib/spack-env/deep"
    : > "${BUNDLE_ROOT}/setups/mclib/.activate.sh"
    printf 'setup\n'   > "${BUNDLE_ROOT}/setups/mclib/.setup.type"
    printf 'sid\n'     > "${BUNDLE_ROOT}/setups/mclib/.setup.id"
    printf 'spack:\n'  > "${BUNDLE_ROOT}/setups/mclib/spack.yaml"
    printf 'lock\n'    > "${BUNDLE_ROOT}/setups/mclib/spack.lock"
    printf 'binary\n'  > "${BUNDLE_ROOT}/setups/mclib/spack-env/deep/lib.so"

    mkdir -p "${BUNDLE_ROOT}/jobs/job1"
    printf 'out\n'     > "${BUNDLE_ROOT}/jobs/job1/.stdout"
    printf 'err\n'     > "${BUNDLE_ROOT}/jobs/job1/.stderr"
    printf '#!/bin/sh\n' > "${BUNDLE_ROOT}/jobs/job1/.job.sh"
    printf '42\n'      > "${BUNDLE_ROOT}/jobs/job1/.job.id"
    printf 'meta\n'    > "${BUNDLE_ROOT}/jobs/job1/.submit"
    printf 'x,y\n'     > "${BUNDLE_ROOT}/jobs/job1/slice.csv"

    mkdir -p "${BUNDLE_ROOT}/artifacts"
    printf 'result\n'  > "${BUNDLE_ROOT}/artifacts/result.txt"

    mkdir -p "${BUNDLE_ROOT}/resources/dataset"
    printf 'data\n'    > "${BUNDLE_ROOT}/resources/dataset/file.dat"
    printf 'image\n'   > "${BUNDLE_ROOT}/resources/.dataset.resource.type"

    mkdir -p "${BUNDLE_ROOT}/.knit/spack" "${BUNDLE_ROOT}/.knit/sqlite" \
             "${BUNDLE_ROOT}/.knit/jq"
    printf 'x\n'       > "${BUNDLE_ROOT}/.knit/spack/foo"
}

@test "collect includes setup manifests, job logs and scripts, and artifacts by default" {
    _populate_tree
    local -A opts=()
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    run _collect_has "setups/mclib/.activate.sh" "${out[@]}"; [ "${status}" -eq 0 ]
    run _collect_has "setups/mclib/.setup.type"  "${out[@]}"; [ "${status}" -eq 0 ]
    run _collect_has "setups/mclib/.setup.id"    "${out[@]}"; [ "${status}" -eq 0 ]
    run _collect_has "setups/mclib/spack.yaml"   "${out[@]}"; [ "${status}" -eq 0 ]
    run _collect_has "setups/mclib/spack.lock"   "${out[@]}"; [ "${status}" -eq 0 ]
    run _collect_has "jobs/job1/.stdout"         "${out[@]}"; [ "${status}" -eq 0 ]
    run _collect_has "jobs/job1/.stderr"         "${out[@]}"; [ "${status}" -eq 0 ]
    run _collect_has "jobs/job1/.job.sh"         "${out[@]}"; [ "${status}" -eq 0 ]
    run _collect_has "jobs/job1/.job.id"         "${out[@]}"; [ "${status}" -eq 0 ]
    run _collect_has "artifacts"                 "${out[@]}"; [ "${status}" -eq 0 ]
}

@test "collect prunes a setup's built spack-env tree" {
    _populate_tree
    local -A opts=()
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    run _collect_has "setups/mclib/spack-env" "${out[@]}"
    [ "${status}" -ne 0 ]
    run _collect_has "setups/mclib/spack-env/deep/lib.so" "${out[@]}"
    [ "${status}" -ne 0 ]
}

@test "collect never packs the provisioned tools under .knit" {
    _populate_tree
    local -A opts=()
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    # The pruned .knit carries the database only.
    run _collect_has ".knit/knit.db" "${out[@]}"; [ "${status}" -eq 0 ]
    local e bad=""
    for e in "${out[@]}"; do
        case "${e}" in
            .knit/spack*|.knit/sqlite*|.knit/jq*) bad="${e}" ;;
        esac
    done
    [ -z "${bad}" ]
}

@test "--no-knit drops the knit.sh framework file" {
    _populate_tree
    local -A opts=([no_knit]=true)
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    run _collect_has "knit.sh" "${out[@]}"
    [ "${status}" -ne 0 ]
}

@test "--no-db drops the provenance database" {
    _populate_tree
    local -A opts=([no_db]=true)
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    run _collect_has ".knit/knit.db" "${out[@]}"
    [ "${status}" -ne 0 ]
}

@test "--no-job-logs drops job logs but keeps job scripts" {
    _populate_tree
    local -A opts=([no_job_logs]=true)
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    run _collect_has "jobs/job1/.stdout" "${out[@]}"; [ "${status}" -ne 0 ]
    run _collect_has "jobs/job1/.stderr" "${out[@]}"; [ "${status}" -ne 0 ]
    run _collect_has "jobs/job1/.job.sh" "${out[@]}"; [ "${status}" -eq 0 ]
}

@test "--no-job-scripts drops job scripts but keeps job logs" {
    _populate_tree
    local -A opts=([no_job_scripts]=true)
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    run _collect_has "jobs/job1/.job.sh" "${out[@]}"; [ "${status}" -ne 0 ]
    run _collect_has "jobs/job1/.job.id" "${out[@]}"; [ "${status}" -ne 0 ]
    run _collect_has "jobs/job1/.stdout" "${out[@]}"; [ "${status}" -eq 0 ]
}

@test "--no-artifacts drops the artifacts tree" {
    _populate_tree
    local -A opts=([no_artifacts]=true)
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    run _collect_has "artifacts" "${out[@]}"
    [ "${status}" -ne 0 ]
}

@test "job user content is excluded by default" {
    _populate_tree
    local -A opts=()
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    run _collect_has "jobs/job1/slice.csv" "${out[@]}"
    [ "${status}" -ne 0 ]
}

@test "--include-job-content packs job user content but not the framework dotfiles" {
    _populate_tree
    local -A opts=([include_job_content]=true)
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    run _collect_has "jobs/job1/slice.csv" "${out[@]}"; [ "${status}" -eq 0 ]
    # The submit-metadata dotfile is framework internal, never user content.
    run _collect_has "jobs/job1/.submit" "${out[@]}"; [ "${status}" -ne 0 ]
}

@test "fetched resources are excluded by default" {
    _populate_tree
    local -A opts=()
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    run _collect_has "resources/dataset" "${out[@]}"
    [ "${status}" -ne 0 ]
}

@test "--include-resources packs the named resource only" {
    _populate_tree
    mkdir -p "${BUNDLE_ROOT}/resources/other"
    printf 'o\n' > "${BUNDLE_ROOT}/resources/other/x"
    local -A opts=([include_resources]=dataset)
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    run _collect_has "resources/dataset" "${out[@]}"; [ "${status}" -eq 0 ]
    run _collect_has "resources/other"   "${out[@]}"; [ "${status}" -ne 0 ]
}

@test "--include-all-resources packs every instance but not the sidecar markers" {
    _populate_tree
    mkdir -p "${BUNDLE_ROOT}/resources/other"
    printf 'o\n' > "${BUNDLE_ROOT}/resources/other/x"
    local -A opts=([include_all_resources]=true)
    local -a out=()
    _knit_bundle_collect out opts "${BUNDLE_ROOT}"
    run _collect_has "resources/dataset" "${out[@]}"; [ "${status}" -eq 0 ]
    run _collect_has "resources/other"   "${out[@]}"; [ "${status}" -eq 0 ]
    run _collect_has "resources/.dataset.resource.type" "${out[@]}"
    [ "${status}" -ne 0 ]
}

@test "bundle fatals when both resource selectors are given" {
    _populate_tree
    local out="${BUNDLE_ROOT}/out.tar.gz"
    run _knit_bundle --output "${out}" \
        --include-all-resources true --include-resources dataset
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"mutually exclusive"* ]]
}

# ---------- --dry-run, --list, --size (M4) ----------

@test "--dry-run writes no archive" {
    _populate_tree
    local out="${BUNDLE_ROOT}/out.tar.gz"
    run _knit_bundle --output "${out}" --dry-run true
    [ "${status}" -eq 0 ]
    [ ! -e "${out}" ]
}

@test "--dry-run prints a tree that lists the expected entries" {
    _populate_tree
    run _knit_bundle --dry-run true
    [ "${status}" -eq 0 ]
    # The synthesized intermediate directories appear as tree nodes.
    [[ "${output}" == *"experiment.sh"* ]]
    [[ "${output}" == *"knit.sh"* ]]
    [[ "${output}" == *".knit/"* || "${output}" == *"knit.db"* ]]
    [[ "${output}" == *"setups/"* ]]
    [[ "${output}" == *"mclib/"* ]]
    [[ "${output}" == *"jobs/"* ]]
    [[ "${output}" == *"artifacts/"* ]]
    # A box connector is present, so the output is drawn as a tree.
    [[ "${output}" == *"── "* ]]
}

@test "--dry-run tree header is the archive root name" {
    _populate_tree
    _knit_sqlite3_write \
        "INSERT INTO metadata (key, value) VALUES ('__project__', 'montecarlo-pi');"
    run _knit_bundle --dry-run true
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"montecarlo-pi-bundle/"* ]]
}

@test "--dry-run --list prints a flat, root-relative path list" {
    _populate_tree
    run _knit_bundle --dry-run true --list true
    [ "${status}" -eq 0 ]
    # Every line is a bare relative path: no box connectors, no leading slash.
    [[ "${output}" != *"── "* ]]
    local line
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" != /* ]]
    done <<< "${output}"
    [[ "${output}" == *"experiment.sh"* ]]
    [[ "${output}" == *"setups/mclib/.activate.sh"* ]]
    [[ "${output}" == *"artifacts"* ]]
}

@test "--dry-run --list --size annotates paths and totals correctly" {
    _populate_tree
    # A required file of a known size, so the reported byte count is predictable.
    printf '0123456789' > "${BUNDLE_ROOT}/ten.txt"   # exactly 10 bytes, no newline
    knit_bundle_requires "ten.txt"
    run _knit_bundle --dry-run true --list true --size true
    [ "${status}" -eq 0 ]
    # The ten-byte file is annotated with its size.
    [[ "${output}" == *"10  ten.txt"* ]]
    # A TOTAL line closes the report.
    [[ "${output}" == *"TOTAL"* ]]
    # The total equals the sum of the per-entry sizes.
    local sum=0 sz rest
    while read -r sz rest; do
        [[ "${rest}" == "TOTAL" ]] && { [ "${sz}" -eq "${sum}" ]; continue; }
        [[ "${sz}" =~ ^[0-9]+$ ]] && sum=$(( sum + sz ))
    done <<< "${output}"
}

@test "--size counts a symlink's target size, not the link" {
    # A ten-byte target linked in from outside the tree; du -L must follow it.
    local ext; ext="$(mktemp -d)"
    printf '0123456789' > "${ext}/target.txt"        # exactly 10 bytes
    ln -s "${ext}/target.txt" "${BUNDLE_ROOT}/link.txt"
    knit_bundle_requires "link.txt"
    run _knit_bundle --dry-run true --list true --size true
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"10  link.txt"* ]]
    rm -rf "${ext}"
}

@test "--list without --dry-run is a usage error" {
    run _knit_bundle --list true
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"only meaningful with --dry-run"* ]]
}

@test "--size without --dry-run is a usage error" {
    run _knit_bundle --size true
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"only meaningful with --dry-run"* ]]
}

# ---------- requires validation, glob expansion, warnings (M5) ----------

@test "bundle fatals on an absolute required path" {
    knit_bundle_requires "/etc/hosts"
    run _knit_bundle --output "${BUNDLE_ROOT}/out.tar.gz"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"absolute"* ]]
    [[ "${output}" == *"/etc/hosts"* ]]
    [ ! -e "${BUNDLE_ROOT}/out.tar.gz" ]
}

@test "bundle fatals on a required path that escapes the tree" {
    knit_bundle_requires "../evil.txt"
    run _knit_bundle --output "${BUNDLE_ROOT}/out.tar.gz"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"escapes"* ]]
    [ ! -e "${BUNDLE_ROOT}/out.tar.gz" ]
}

@test "bundle expands a required glob and packs every match" {
    mkdir -p "${BUNDLE_ROOT}/inputs"
    printf 'a\n' > "${BUNDLE_ROOT}/inputs/a.dat"
    printf 'b\n' > "${BUNDLE_ROOT}/inputs/b.dat"
    printf 'c\n' > "${BUNDLE_ROOT}/inputs/c.txt"
    knit_bundle_requires "inputs/*.dat"
    local out="${BUNDLE_ROOT}/out.tar.gz"
    _knit_bundle --output "${out}"
    run tar -tzf "${out}"
    [[ "${output}" == *"inputs/a.dat"* ]]
    [[ "${output}" == *"inputs/b.dat"* ]]
    # A non-matching file is left out.
    [[ "${output}" != *"inputs/c.txt"* ]]
}

@test "bundle warns on a required glob that matches nothing, without failing" {
    knit_bundle_requires "inputs/*.dat"
    local out="${BUNDLE_ROOT}/out.tar.gz"
    run _knit_bundle --output "${out}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"matched nothing"* ]]
    [ -e "${out}" ]
}

@test "bundle warns and normalizes an absolute stored root, packing its content" {
    # An artifact root bootstrapped as an absolute path outside the tree, as with
    # results staged on a parallel filesystem.
    local ext; ext="$(mktemp -d)"
    mkdir -p "${ext}/artifacts"
    printf 'result\n' > "${ext}/artifacts/result.txt"
    _knit_sqlite3_write \
        "INSERT INTO metadata (key, value) VALUES ('__artifact_path__', '${ext}/artifacts');"
    local out="${BUNDLE_ROOT}/out.tar.gz"
    run _knit_bundle --output "${out}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"outside the experiment tree"* ]]
    # The content is packed under the normalized relative location.
    run tar -tzf "${out}"
    [[ "${output}" == *"artifacts/result.txt"* ]]
    rm -rf "${ext}"
}

@test "bundle warns about an unselected local-only resource" {
    # Mark a resource type "mydata" as local, as knit_with_local would, then place
    # an instance with its type sidecar. The marker uses the mangled command name.
    _KNIT_CMD_fetch__1__mydata_fetch_method="local"
    mkdir -p "${BUNDLE_ROOT}/resources/ds"
    printf 'x\n' > "${BUNDLE_ROOT}/resources/ds/file"
    printf 'mydata\n' > "${BUNDLE_ROOT}/resources/.ds.resource.type"

    run _knit_bundle --output "${BUNDLE_ROOT}/out.tar.gz"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"local resource"* ]]
    [[ "${output}" == *"ds"* ]]
}

@test "bundle does not warn about a selected local resource" {
    _KNIT_CMD_fetch__1__mydata_fetch_method="local"
    mkdir -p "${BUNDLE_ROOT}/resources/ds"
    printf 'x\n' > "${BUNDLE_ROOT}/resources/ds/file"
    printf 'mydata\n' > "${BUNDLE_ROOT}/resources/.ds.resource.type"

    run _knit_bundle --output "${BUNDLE_ROOT}/out.tar.gz" --include-resources ds
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"local resource"* ]]
}

@test "bundle does not warn about an unselected non-local resource" {
    # A git-backed resource has a remote source, so leaving it out is safe.
    _KNIT_CMD_fetch__1__mydata_fetch_method="git"
    mkdir -p "${BUNDLE_ROOT}/resources/ds"
    printf 'x\n' > "${BUNDLE_ROOT}/resources/ds/file"
    printf 'mydata\n' > "${BUNDLE_ROOT}/resources/.ds.resource.type"

    run _knit_bundle --output "${BUNDLE_ROOT}/out.tar.gz"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"local resource"* ]]
}

# ---------- knit_with_spack_env auto-require (M5) ----------

@test "knit_with_spack_env file form records a bundle auto-require" {
    _KNIT_BUNDLE_AUTO_REQUIRES=()
    _spack_setup_fn() { :; }
    knit_register_setup "libs" "_spack_setup_fn" "Build deps."
    knit_with_spack_env "envs/mclib.yaml"
    knit_done
    run _collect_has "envs/mclib.yaml" "${_KNIT_BUNDLE_AUTO_REQUIRES[@]}"
    [ "${status}" -eq 0 ]
}

@test "knit_with_spack_env stdin form records no bundle auto-require" {
    _KNIT_BUNDLE_AUTO_REQUIRES=()
    _spack_setup_fn() { :; }
    knit_register_setup "libs" "_spack_setup_fn" "Build deps."
    knit_with_spack_env <<'EOF'
spack:
  specs:
    - zlib
EOF
    knit_done
    [ "${#_KNIT_BUNDLE_AUTO_REQUIRES[@]}" -eq 0 ]
}

@test "an auto-required spack manifest is packed into the bundle" {
    mkdir -p "${BUNDLE_ROOT}/envs"
    printf 'spack:\n' > "${BUNDLE_ROOT}/envs/mclib.yaml"
    _KNIT_BUNDLE_AUTO_REQUIRES=("envs/mclib.yaml")
    local out="${BUNDLE_ROOT}/out.tar.gz"
    _knit_bundle --output "${out}"
    run tar -tzf "${out}"
    [[ "${output}" == *"envs/mclib.yaml"* ]]
}

@test "a missing auto-required path warns but does not fatal" {
    # Unlike the user's own required list, an auto-required path is lenient: a
    # missing one is skipped with a warning so the bundle still succeeds.
    _KNIT_BUNDLE_AUTO_REQUIRES=("envs/absent.yaml")
    local out="${BUNDLE_ROOT}/out.tar.gz"
    run _knit_bundle --output "${out}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"envs/absent.yaml"* ]]
    [ -e "${out}" ]
    run tar -tzf "${out}"
    [[ "${output}" != *"envs/absent.yaml"* ]]
}
