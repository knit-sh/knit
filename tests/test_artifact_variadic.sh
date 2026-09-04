#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _knit_create_metadata_table

    # Experiment root = the directory containing .knit.
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

# Point the artifacts root at an absolute directory under the test tmpdir, so a
# body can write into it and its resolved root is predictable.
_use_artifacts_root() {
    _ART_ROOT="${_KNIT_TEST_TMPDIR}/artifacts"
    _knit_metadata_store --key "__artifact_path__" --value "${_ART_ROOT}"
}

# ---------- _knit_artifact_parse_kind ----------

@test "parse kind leaves a scalar kind unchanged with no quantifier" {
    local kind quant
    _knit_artifact_parse_kind kind quant "csvfile" "ctx"
    [ "${kind}" = "csvfile" ]
    [ "${quant}" = "" ]
}

@test "parse kind splits a trailing star quantifier" {
    local kind quant
    _knit_artifact_parse_kind kind quant "csvfile*" "ctx"
    [ "${kind}" = "csvfile" ]
    [ "${quant}" = "*" ]
}

@test "parse kind splits a trailing plus quantifier" {
    local kind quant
    _knit_artifact_parse_kind kind quant "csvfile+" "ctx"
    [ "${kind}" = "csvfile" ]
    [ "${quant}" = "+" ]
}

@test "parse kind is fatal on a doubled quantifier" {
    local kind quant
    run _knit_artifact_parse_kind kind quant "csvfile**" "ctx"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"at most one trailing quantifier"* ]]
}

@test "parse kind is fatal on mixed quantifiers" {
    local kind quant
    run _knit_artifact_parse_kind kind quant "csvfile*+" "ctx"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"at most one trailing quantifier"* ]]
}

# ---------- knit_with_output_artifact (quantifier markers) ----------

@test "output artifact records a star quantifier marker and the bare kind" {
    knit_register "vout_1" knit_empty "A test command."
    knit_with_output_artifact "frames:file*" "One PNG per frame."
    knit_done
    [ "${_KNIT_CMD_vout_1_artifact_variadic_frames}" = "*" ]
    # The bare kind (no quantifier) is what is recorded and later written to the row.
    [ "${_KNIT_CMD_vout_1_3_frames_type}" = "file" ]
}

@test "output artifact records a plus quantifier marker" {
    knit_register "vout_2" knit_empty "A test command."
    knit_with_output_artifact "frames:file+" "At least one PNG."
    knit_done
    [ "${_KNIT_CMD_vout_2_artifact_variadic_frames}" = "+" ]
}

@test "output artifact declares no quantifier marker for a scalar" {
    knit_register "vout_3" knit_empty "A test command."
    knit_with_output_artifact "table:file" "A single table."
    knit_done
    [ -z "${_KNIT_CMD_vout_3_artifact_variadic_table:-}" ]
}

@test "output artifact accepts a quantifier on a user kind, keeping the bare kind" {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "vout_4" knit_empty "A test command."
    knit_with_output_artifact "tables:csvfile+" "One or more tables."
    knit_done
    [ "${_KNIT_CMD_vout_4_artifact_variadic_tables}" = "+" ]
    [ "${_KNIT_CMD_vout_4_3_tables_type}" = "csvfile" ]
}

@test "output artifact is fatal on a doubled quantifier" {
    knit_register "vout_5" knit_empty "A test command."
    run knit_with_output_artifact "frames:file**" "Bad."
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"at most one trailing quantifier"* ]]
    knit_done
}

# ---------- knit_artifact (scalar bind-once guard) ----------

@test "a scalar artifact bound to two paths is fatal" {
    _use_artifacts_root
    knit_register "vb_scalar" fn_vb_scalar "Test."
    knit_with_table
    knit_with_output_artifact "table:file" "A single table."
    fn_vb_scalar() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        printf 'a\n' > "${out}/a.csv"
        printf 'b\n' > "${out}/b.csv"
        knit_artifact "table" "a.csv"
        knit_artifact "table" "b.csv"
    }
    knit_done
    run _knit_invoke_command "vb_scalar"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already bound"* ]]
}

# ---------- knit_artifact (variadic bind) ----------

@test "a variadic star artifact records one row and one produced edge per member" {
    _use_artifacts_root
    knit_register "vb_star" fn_vb_star "Test."
    knit_with_table
    knit_with_output_artifact "frames:file*" "One PNG per frame."
    fn_vb_star() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        printf '1\n' > "${out}/f1.png"
        printf '2\n' > "${out}/f2.png"
        printf '3\n' > "${out}/f3.png"
        knit_artifact "frames" "f1.png"
        knit_artifact "frames" "f2.png"
        knit_artifact "frames" "f3.png"
    }
    knit_done
    _knit_invoke_command "vb_star"
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM artifacts;")" -eq 3 ]
    [ "$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM __provenance__ WHERE edge_type='produced';")" -eq 3 ]
    # Every member carries the one declared name.
    [ "$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM artifacts WHERE name='frames';")" -eq 3 ]
    # All three produced edges hang off the single producing row.
    local rid
    rid=$(_knit_sqlite3 "SELECT id FROM vb_star;")
    [ "$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM __provenance__ \
         WHERE edge_type='produced' AND source_id='${rid}';")" -eq 3 ]
}

@test "a variadic artifact still rejects binding the same path twice" {
    _use_artifacts_root
    knit_register "vb_dup" fn_vb_dup "Test."
    knit_with_table
    knit_with_output_artifact "frames:file*" "One PNG per frame."
    fn_vb_dup() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        printf '1\n' > "${out}/f1.png"
        knit_artifact "frames" "f1.png"
        knit_artifact "frames" "f1.png"
    }
    knit_done
    run _knit_invoke_command "vb_dup"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"write-once"* ]]
}

@test "a plus artifact that binds nothing is fatal" {
    _use_artifacts_root
    knit_register "vb_plus_empty" fn_vb_plus_empty "Test."
    knit_with_table
    knit_with_output_artifact "frames:file+" "At least one PNG."
    # shellcheck disable=SC2317 # invoked through _knit_invoke_command
    fn_vb_plus_empty() { :; }
    knit_done
    run _knit_invoke_command "vb_plus_empty"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"one or more"* ]]
    [[ "${output}" == *"at least one"* ]]
}

@test "a star artifact that binds nothing succeeds and records no artifact" {
    _use_artifacts_root
    knit_register "vb_star_empty" fn_vb_star_empty "Test."
    knit_with_table
    knit_with_output_artifact "frames:file*" "Zero or more PNGs."
    # shellcheck disable=SC2317 # invoked through _knit_invoke_command
    fn_vb_star_empty() { :; }
    knit_done
    _knit_invoke_command "vb_star_empty"
    # The command's own row is recorded, but no artifact and no produced edge. A
    # command that bound nothing never even creates the artifacts table.
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM vb_star_empty;")" -eq 1 ]
    [ "$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master \
         WHERE type='table' AND name='artifacts';")" -eq 0 ]
    [ "$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM __provenance__ WHERE edge_type='produced';")" -eq 0 ]
}

@test "--result marks every member of a variadic collection" {
    _use_artifacts_root
    knit_register "vb_result" fn_vb_result "Test."
    knit_with_table
    knit_with_output_artifact "frames:file*" "One PNG per frame." --result
    fn_vb_result() {
        local out; out="$(knit_artifact_dir)"
        mkdir -p "${out}"
        printf '1\n' > "${out}/f1.png"
        printf '2\n' > "${out}/f2.png"
        knit_artifact "frames" "f1.png"
        knit_artifact "frames" "f2.png"
    }
    knit_done
    _knit_invoke_command "vb_result"
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM artifacts WHERE result=1;")" -eq 2 ]
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM artifacts WHERE result=0;")" -eq 0 ]
}
