#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _knit_create_metadata_table
    _knit_artifacts_create_table

    # Experiment root = the directory containing .knit.
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    # Artifacts live under <experiment-root>/artifacts by default, which is what
    # _knit_artifact_root resolves to (no metadata override needed).
    _ART_ROOT="${_KNIT_TEST_TMPDIR}/artifacts"
    mkdir -p "${_ART_ROOT}"
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

# Insert one artifacts row: path name type kind checksum [result].
_seed_artifact() {
    local path="$1" name="$2" type="$3" kind="$4" checksum="$5" result="${6:-0}"
    local sql
    sql="$(_knit_artifacts_row_sql \
        "id-${path}" "${path}" "${name}" "${type}" "${kind}" "${checksum}" "${result}")"
    _knit_sqlite3_write <<< "${sql}"
}

# ---------- _knit_input_artifact_resolve_list: split ----------

@test "resolve list splits verbatim elements on the comma" {
    local -a out
    _knit_input_artifact_resolve_list out "a.csv,b.csv" "${_ART_ROOT}"
    [ "${#out[@]}" -eq 2 ]
    [ "${out[0]}" = "a.csv" ]
    [ "${out[1]}" = "b.csv" ]
}

@test "resolve list preserves element order" {
    local -a out
    _knit_input_artifact_resolve_list out "b.csv,a.csv" "${_ART_ROOT}"
    [ "${out[0]}" = "b.csv" ]
    [ "${out[1]}" = "a.csv" ]
}

@test "resolve list dedupes a repeated verbatim element first-seen" {
    local -a out
    _knit_input_artifact_resolve_list out "a.csv,a.csv,b.csv" "${_ART_ROOT}"
    [ "${#out[@]}" -eq 2 ]
    [ "${out[0]}" = "a.csv" ]
    [ "${out[1]}" = "b.csv" ]
}

@test "resolve list skips empty elements" {
    local -a out
    _knit_input_artifact_resolve_list out "a.csv,,b.csv," "${_ART_ROOT}"
    [ "${#out[@]}" -eq 2 ]
    [ "${out[0]}" = "a.csv" ]
    [ "${out[1]}" = "b.csv" ]
}

@test "resolve list returns nothing for an empty value" {
    local -a out
    _knit_input_artifact_resolve_list out "" "${_ART_ROOT}"
    [ "${#out[@]}" -eq 0 ]
}

# ---------- _knit_input_artifact_resolve_list: glob ----------

@test "resolve list expands a glob relative to the artifacts root, sorted" {
    mkdir -p "${_ART_ROOT}/tables"
    : > "${_ART_ROOT}/tables/b.csv"
    : > "${_ART_ROOT}/tables/a.csv"
    local -a out
    _knit_input_artifact_resolve_list out "tables/*.csv" "${_ART_ROOT}"
    [ "${#out[@]}" -eq 2 ]
    [ "${out[0]}" = "tables/a.csv" ]
    [ "${out[1]}" = "tables/b.csv" ]
}

@test "resolve list yields nothing when a glob matches no file" {
    mkdir -p "${_ART_ROOT}/tables"
    local -a out
    _knit_input_artifact_resolve_list out "tables/*.csv" "${_ART_ROOT}"
    [ "${#out[@]}" -eq 0 ]
}

@test "resolve list dedupes overlapping globs and verbatim first-seen" {
    mkdir -p "${_ART_ROOT}/t"
    : > "${_ART_ROOT}/t/a.csv"
    : > "${_ART_ROOT}/t/b.csv"
    local -a out
    _knit_input_artifact_resolve_list out "t/a.csv,t/*.csv" "${_ART_ROOT}"
    # t/a.csv is seen verbatim first, so the glob only adds t/b.csv.
    [ "${#out[@]}" -eq 2 ]
    [ "${out[0]}" = "t/a.csv" ]
    [ "${out[1]}" = "t/b.csv" ]
}

@test "resolve list keeps a matched path that contains a space" {
    mkdir -p "${_ART_ROOT}/my dir"
    : > "${_ART_ROOT}/my dir/a.csv"
    local -a out
    _knit_input_artifact_resolve_list out "my dir/*.csv" "${_ART_ROOT}"
    [ "${#out[@]}" -eq 1 ]
    [ "${out[0]}" = "my dir/a.csv" ]
}

@test "resolve list does not recurse even when globstar is enabled" {
    shopt -s globstar
    mkdir -p "${_ART_ROOT}/d/sub"
    : > "${_ART_ROOT}/d/top.csv"
    : > "${_ART_ROOT}/d/sub/deep.csv"
    local -a out
    _knit_input_artifact_resolve_list out "d/**/*.csv" "${_ART_ROOT}"
    # The resolver forces globstar off, so "**" matches one level only: the single
    # d/sub/deep.csv, never the top-level d/top.csv.
    [ "${#out[@]}" -eq 1 ]
    [ "${out[0]}" = "d/sub/deep.csv" ]
    # It also restored the caller's globstar (it was on before the call).
    shopt -q globstar
    shopt -u globstar
}

@test "resolve list restores nullglob to its prior off state" {
    shopt -u nullglob
    local -a out
    _knit_input_artifact_resolve_list out "a.csv" "${_ART_ROOT}"
    ! shopt -q nullglob
}

# ---------- _knit_input_artifact_before_cb: variadic ----------

@test "variadic + before-cb passes when every element is a recorded artifact" {
    _seed_artifact "tables/a.csv" "t" "file" "csvfile" "sha256:x" 0
    _seed_artifact "tables/b.csv" "t" "file" "csvfile" "sha256:y" 0
    run _knit_input_artifact_before_cb "tables" "csvfile" "" "+" \
        --tables "tables/a.csv,tables/b.csv"
    [ "${status}" -eq 0 ]
}

@test "variadic + before-cb is fatal when the list resolves to nothing" {
    mkdir -p "${_ART_ROOT}/tables"
    run _knit_input_artifact_before_cb "tables" "csvfile" "" "+" \
        --tables "tables/*.csv"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"at least one artifact of kind"* ]]
    [[ "${output}" == *"resolved to nothing"* ]]
    [[ "${output}" == *"--tables"* ]]
}

@test "variadic star before-cb accepts an empty list" {
    run _knit_input_artifact_before_cb "tables" "csvfile" "" "*" --tables ""
    [ "${status}" -eq 0 ]
}

@test "variadic star before-cb accepts an absent value" {
    run _knit_input_artifact_before_cb "tables" "csvfile" "" "*"
    [ "${status}" -eq 0 ]
}

@test "variadic before-cb is fatal on the first bad element and names it" {
    _seed_artifact "tables/a.csv" "t" "file" "csvfile" "sha256:x" 0
    run _knit_input_artifact_before_cb "tables" "csvfile" "" "+" \
        --tables "tables/a.csv,tables/missing.csv"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *'No artifact recorded at path "tables/missing.csv"'* ]]
}

@test "variadic before-cb is fatal on a per-element kind mismatch" {
    _seed_artifact "tables/a.csv" "t" "file" "csvfile" "sha256:x" 0
    _seed_artifact "figs/f.svg" "f" "file" "svgfile" "sha256:z" 0
    run _knit_input_artifact_before_cb "tables" "csvfile" "" "+" \
        --tables "tables/a.csv,figs/f.svg"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *'is of kind "svgfile"'* ]]
    [[ "${output}" == *"figs/f.svg"* ]]
}

@test "variadic before-cb verifies the checksum of every element" {
    mkdir -p "${_ART_ROOT}/tables"
    printf 'A\n' > "${_ART_ROOT}/tables/a.csv"
    printf 'B\n' > "${_ART_ROOT}/tables/b.csv"
    local ha
    _knit_sha256 ha "${_ART_ROOT}/tables/a.csv"
    _seed_artifact "tables/a.csv" "t" "file" "csvfile" "sha256:${ha}" 0
    _seed_artifact "tables/b.csv" "t" "file" "csvfile" "sha256:deadbeef" 0
    run _knit_input_artifact_before_cb "tables" "csvfile" "1" "+" \
        --tables "tables/a.csv,tables/b.csv"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"tables/b.csv"* ]]
    [[ "${output}" == *"failed checksum verification"* ]]
}

@test "variadic before-cb accepts a glob that matches recorded artifacts" {
    mkdir -p "${_ART_ROOT}/tables"
    : > "${_ART_ROOT}/tables/a.csv"
    : > "${_ART_ROOT}/tables/b.csv"
    _seed_artifact "tables/a.csv" "t" "file" "csvfile" "sha256:x" 0
    _seed_artifact "tables/b.csv" "t" "file" "csvfile" "sha256:y" 0
    run _knit_input_artifact_before_cb "tables" "csvfile" "" "+" \
        --tables "tables/*.csv"
    [ "${status}" -eq 0 ]
}

@test "variadic before-cb is fatal when a globbed file is not a recorded artifact" {
    mkdir -p "${_ART_ROOT}/tables"
    : > "${_ART_ROOT}/tables/a.csv"
    : > "${_ART_ROOT}/tables/b.csv"
    _seed_artifact "tables/a.csv" "t" "file" "csvfile" "sha256:x" 0
    # b.csv exists on disk (so the glob matches it) but has no artifacts row.
    run _knit_input_artifact_before_cb "tables" "csvfile" "" "+" \
        --tables "tables/*.csv"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *'No artifact recorded at path "tables/b.csv"'* ]]
}

# ---------- knit_with_input_artifact: variadic declaration ----------

@test "knit_with_input_artifact + registers a required parameter and a marker" {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "vin_plus" knit_empty "A consumer."
    knit_with_input_artifact "tables:csvfile+" "The tables."
    knit_done
    _knit_set_find "_KNIT_CMD_vin_plus_required" "tables"
    [ "${_KNIT_CMD_vin_plus_input_artifact_variadic_tables}" = "+" ]
    [ "${_KNIT_CMD_vin_plus_input_artifact_tables}" = "csvfile" ]
}

@test "knit_with_input_artifact star registers an optional parameter defaulting to empty" {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "vin_star" knit_empty "A consumer."
    knit_with_input_artifact "tables:csvfile*" "The tables."
    knit_done
    _knit_set_find "_KNIT_CMD_vin_star_optional" "tables"
    [ "${_KNIT_CMD_vin_star_input_artifact_variadic_tables}" = "*" ]
    [ -z "${_KNIT_CMD_vin_star_2_tables_default}" ]
}

@test "knit_with_input_artifact records no variadic marker for a scalar input" {
    knit_register "vin_scalar" knit_empty "A consumer."
    knit_with_input_artifact "table:file" "The table."
    knit_done
    [ -z "${_KNIT_CMD_vin_scalar_input_artifact_variadic_table:-}" ]
    _knit_set_find "_KNIT_CMD_vin_scalar_required" "table"
}

@test "knit_with_input_artifact strips the quantifier and stores the bare kind" {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "vin_bare" knit_empty "A consumer."
    knit_with_input_artifact "tables:csvfile+" "The tables."
    knit_done
    [ "${_KNIT_CMD_vin_bare_input_artifact_tables}" = "csvfile" ]
}

@test "knit_with_input_artifact is fatal on a doubled quantifier" {
    knit_register "vin_bad" knit_empty "A consumer."
    run knit_with_input_artifact "tables:file**" "Bad."
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"at most one trailing quantifier"* ]]
    knit_done
}

@test "knit_with_input_artifact binds the quantifier into the before-callback" {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "vin_cb" knit_empty "A consumer."
    knit_with_input_artifact "tables:csvfile+" "The tables."
    knit_done
    local -n _bcbs="_KNIT_CMD_vin_cb_before_cb"
    [[ "${_bcbs[*]}" == *"_knit_input_artifact_before_cb"* ]]
    [[ "${_bcbs[*]}" == *"+"* ]]
}
