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
    # Artifacts live under <experiment-root>/artifacts by default.
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
        "id-${name}" "${path}" "${name}" "${type}" "${kind}" "${checksum}" "${result}")"
    _knit_sqlite3_write <<< "${sql}"
}

# ---------- knit_with_input_artifact: declaration ----------

@test "knit_with_input_artifact registers a required string parameter" {
    knit_register "in_cmd_1" knit_empty "A consumer."
    knit_with_input_artifact "input_table:file" "The table to read."
    knit_done
    _knit_set_find "_KNIT_CMD_in_cmd_1_required" "input_table"
    [ "${_KNIT_CMD_in_cmd_1_2_input_table_type}" = "string" ]
}

@test "knit_with_input_artifact records the required kind in a per-parameter marker" {
    knit_register_artifact "csvfile:file" "Tabulated result in CSV format."
    knit_register "in_cmd_2" knit_empty "A consumer."
    knit_with_input_artifact "input_table:csvfile" "The table to read."
    knit_done
    [ "${_KNIT_CMD_in_cmd_2_input_artifact_input_table}" = "csvfile" ]
}

@test "knit_with_input_artifact records no verify marker by default" {
    knit_register "in_cmd_3" knit_empty "A consumer."
    knit_with_input_artifact "input_table:file" "The table to read."
    knit_done
    [ -z "${_KNIT_CMD_in_cmd_3_input_artifact_verify_input_table:-}" ]
}

@test "knit_with_input_artifact records a verify marker with --verify-checksum" {
    knit_register "in_cmd_4" knit_empty "A consumer."
    knit_with_input_artifact "input_table:file" "The table to read." --verify-checksum
    knit_done
    [ "${_KNIT_CMD_in_cmd_4_input_artifact_verify_input_table}" = "1" ]
}

@test "knit_with_input_artifact normalizes a hyphen in the parameter name" {
    knit_register "in_cmd_5" knit_empty "A consumer."
    knit_with_input_artifact "my-table:file" "The table to read."
    knit_done
    _knit_set_find "_KNIT_CMD_in_cmd_5_required" "my_table"
    [ "${_KNIT_CMD_in_cmd_5_input_artifact_my_table}" = "file" ]
}

@test "knit_with_input_artifact accepts a bare builtin directory kind" {
    knit_register "in_cmd_6" knit_empty "A consumer."
    knit_with_input_artifact "run_dir:directory" "The run directory."
    knit_done
    [ "${_KNIT_CMD_in_cmd_6_input_artifact_run_dir}" = "directory" ]
}

@test "knit_with_input_artifact supplies a default description" {
    knit_register "in_cmd_7" knit_empty "A consumer."
    knit_with_input_artifact "input_table:file"
    knit_done
    [[ "${_KNIT_CMD_in_cmd_7_2_input_table_description}" == *"Input artifact of kind"* ]]
}

# ---------- knit_with_input_artifact: declaration guards ----------

@test "knit_with_input_artifact is fatal outside a command" {
    run knit_with_input_artifact "input_table:file" "Nope."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"between a knit_register"* ]]
}

@test "knit_with_input_artifact is fatal on a wrapper" {
    wrap_fn() { :; }
    knit_register_wrapper "in_wrap" "wrap_fn" "A wrapper."
    run knit_with_input_artifact "input_table:file" "Nope."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot be used with a wrapper command"* ]]
    knit_done
}

@test "knit_with_input_artifact is fatal without a kind annotation" {
    knit_register "in_cmd_8" knit_empty "A consumer."
    run knit_with_input_artifact "input_table" "No kind."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"name:kind"* ]]
    knit_done
}

@test "knit_with_input_artifact is fatal on an empty kind" {
    knit_register "in_cmd_9" knit_empty "A consumer."
    run knit_with_input_artifact "input_table:" "Empty kind."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"kind after the colon"* ]]
    knit_done
}

@test "knit_with_input_artifact is fatal on an invalid parameter name" {
    knit_register "in_cmd_10" knit_empty "A consumer."
    run knit_with_input_artifact "-bad:file" "Bad name."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not a valid parameter name"* ]]
    knit_done
}

@test "knit_with_input_artifact is fatal on an unknown kind" {
    knit_register "in_cmd_11" knit_empty "A consumer."
    run knit_with_input_artifact "input_table:nosuchkind" "Unknown kind."
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unknown artifact kind"* ]]
    knit_done
}

@test "knit_with_input_artifact rejects an unexpected argument" {
    knit_register "in_cmd_12" knit_empty "A consumer."
    run knit_with_input_artifact "input_table:file" "Desc." --bogus
    [ "${status}" -eq 1 ]
    knit_done
}

# ---------- knit_input_artifact_path ----------

@test "knit_input_artifact_path resolves a relative path to its absolute location" {
    printf 'data\n' > "${_ART_ROOT}/table.csv"
    run knit_input_artifact_path "table.csv"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${_ART_ROOT}/table.csv" ]
}

@test "knit_input_artifact_path resolves a nested relative path" {
    mkdir -p "${_ART_ROOT}/tables"
    printf 'data\n' > "${_ART_ROOT}/tables/run7.csv"
    run knit_input_artifact_path "tables/run7.csv"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${_ART_ROOT}/tables/run7.csv" ]
}

@test "knit_input_artifact_path is fatal on an empty value" {
    run knit_input_artifact_path ""
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"requires an artifact path"* ]]
}

@test "knit_input_artifact_path is fatal on a path outside the artifacts root" {
    run knit_input_artifact_path "/etc/passwd"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"outside the artifacts directory"* ]]
}

@test "knit_input_artifact_path is fatal when the entry does not exist" {
    run knit_input_artifact_path "missing.csv"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not found"* ]]
}

# ---------- _knit_input_artifact_before_cb ----------

@test "before-cb is fatal on an empty parameter value" {
    run _knit_input_artifact_before_cb "input_table" "csvfile" ""
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"requires an artifact of kind"* ]]
    [[ "${output}" == *"--input-table"* ]]
}

@test "before-cb is fatal when no artifact is recorded at the path" {
    run _knit_input_artifact_before_cb "input_table" "csvfile" "" \
        --input-table "tables/absent.csv"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No artifact recorded at path"* ]]
}

@test "before-cb passes when the recorded kind matches" {
    _seed_artifact "tables/run7.csv" "table" "file" "csvfile" "sha256:abc" 0
    run _knit_input_artifact_before_cb "input_table" "csvfile" "" \
        --input-table "tables/run7.csv"
    [ "${status}" -eq 0 ]
}

@test "before-cb is fatal on a kind mismatch" {
    _seed_artifact "figures/fig.svg" "figure" "file" "svgfile" "sha256:abc" 0
    run _knit_input_artifact_before_cb "input_table" "csvfile" "" \
        --input-table "figures/fig.svg"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"is of kind \"svgfile\""* ]]
    [[ "${output}" == *"\"csvfile\" is required"* ]]
}

@test "before-cb treats an unbootstrapped experiment as a missing artifact" {
    _seed_artifact "tables/run7.csv" "table" "file" "csvfile" "sha256:abc" 0
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/nonexistent"
    run _knit_input_artifact_before_cb "input_table" "csvfile" "" \
        --input-table "tables/run7.csv"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No artifact recorded at path"* ]]
}

# ---------- _knit_input_artifact_before_cb: --verify-checksum ----------

@test "before-cb verify passes when the checksum matches" {
    mkdir -p "${_ART_ROOT}/tables"
    printf 'the-data\n' > "${_ART_ROOT}/tables/run7.csv"
    local hex
    _knit_sha256 hex "${_ART_ROOT}/tables/run7.csv"
    _seed_artifact "tables/run7.csv" "table" "file" "csvfile" "sha256:${hex}" 0
    run _knit_input_artifact_before_cb "input_table" "csvfile" "1" \
        --input-table "tables/run7.csv"
    [ "${status}" -eq 0 ]
}

@test "before-cb verify is fatal when the checksum differs" {
    mkdir -p "${_ART_ROOT}/tables"
    printf 'the-data\n' > "${_ART_ROOT}/tables/run7.csv"
    _seed_artifact "tables/run7.csv" "table" "file" "csvfile" "sha256:deadbeef" 0
    run _knit_input_artifact_before_cb "input_table" "csvfile" "1" \
        --input-table "tables/run7.csv"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"failed checksum verification"* ]]
}

# ---------- used_by edges ----------

@test "knit_with_input_artifact installs the validation before-callback" {
    knit_register "consume_1" knit_empty "A consumer."
    knit_with_input_artifact "input_table:file" "The table."
    knit_done
    local -n _bcbs="_KNIT_CMD_consume_1_before_cb"
    [[ "${_bcbs[*]}" == *"_knit_input_artifact_before_cb"* ]]
}

@test "knit_with_input_artifact installs the used_by-edge after-callback" {
    knit_register "consume_2" knit_empty "A consumer."
    knit_with_input_artifact "input_table:file" "The table."
    knit_done
    local -n _acbs="_KNIT_CMD_consume_2_after_cb"
    [[ "${_acbs[*]}" == *"_knit_input_artifact_after_cb"* ]]
}

@test "a consumer with knit_with_input_artifact records a used_by edge to the artifact" {
    knit_register_artifact "csvfile:file" "A CSV table."
    _seed_artifact "tables/run7.csv" "table" "file" "csvfile" "sha256:abc" 0
    knit_register "plot" _plot "Plot."
    knit_with_table "plot"
    knit_with_input_artifact "input_table:csvfile" "The table."
    _plot() { :; }
    knit_done
    _knit_invoke_command "plot" --input-table "tables/run7.csv"
    # The edge's source is the artifacts row (id from the seeded row, name the
    # "artifacts" node label), its target is the consumer's recorded row, and it
    # has no duration.
    [ "$(_knit_sqlite3 \
        "SELECT source_id,source_name,target_name,edge_type,start_time,end_time FROM ${_KNIT_PROV_TABLE} WHERE edge_type='used_by';")" \
        = "id-table|artifacts|plot|used_by||" ]
    [ "$(_knit_sqlite3 "SELECT target_id FROM ${_KNIT_PROV_TABLE} WHERE edge_type='used_by';")" \
        = "$(_knit_sqlite3 'SELECT id FROM plot;')" ]
}

@test "a consumer records no used_by edge when no artifact row exists at the path" {
    # Seed a different path so the recorded artifact does not match the value; the
    # before-callback would normally fatal, so drive the after-callback directly.
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "plot" _plot "Plot."
    knit_with_table "plot"
    knit_with_input_artifact "input_table:csvfile" "The table."
    _plot() { :; }
    knit_done
    _KNIT_EXECUTING_COMMAND=("$(_knit_command_mangle "plot")")
    _KNIT_EXECUTING_ROW_ID=("target-uuid-1")
    _knit_input_artifact_after_cb "input_table" "csvfile" "" \
        --input-table "tables/absent.csv"
    _knit_prov_ensure_table
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM ${_KNIT_PROV_TABLE} WHERE edge_type='used_by';")" = "0" ]
}

@test "_knit_input_artifact_record_used_by_edge writes source, target, and NULL timestamps" {
    _seed_artifact "tables/run7.csv" "table" "file" "csvfile" "sha256:abc" 0
    knit_register "plot" _plot "Plot."
    _plot() { :; }
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "plot")
    _knit_input_artifact_record_used_by_edge "tables/run7.csv" "${cmd}" "target-uuid-9"
    [ "$(_knit_sqlite3 \
        "SELECT source_id,source_name,target_id,target_name,edge_type,start_time,end_time FROM ${_KNIT_PROV_TABLE};")" \
        = "id-table|artifacts|target-uuid-9|plot|used_by||" ]
}

@test "_knit_input_artifact_record_used_by_edge records nothing for a without-provenance target" {
    _seed_artifact "tables/run7.csv" "table" "file" "csvfile" "sha256:abc" 0
    knit_register "plot" _plot "Plot."
    knit_without_provenance
    _plot() { :; }
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "plot")
    _knit_input_artifact_record_used_by_edge "tables/run7.csv" "${cmd}" "target-uuid-9"
    _knit_prov_ensure_table
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM ${_KNIT_PROV_TABLE};")" = "0" ]
}

@test "the after-callback records nothing when the parameter value is empty" {
    knit_register "plot" _plot "Plot."
    _plot() { :; }
    knit_done
    _knit_input_artifact_after_cb "input_table" "csvfile" "" --input-table ""
    _knit_prov_ensure_table
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM ${_KNIT_PROV_TABLE};")" = "0" ]
}

@test "_knit_input_artifact_record_used_by_edge records nothing when unbootstrapped" {
    _seed_artifact "tables/run7.csv" "table" "file" "csvfile" "sha256:abc" 0
    knit_register "plot" _plot "Plot."
    _plot() { :; }
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "plot")
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/nonexistent"
    _knit_input_artifact_record_used_by_edge "tables/run7.csv" "${cmd}" "target-uuid-9"
    _KNIT_IS_BOOTSTRAPPED="1"
    _knit_prov_ensure_table
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM ${_KNIT_PROV_TABLE} WHERE edge_type='used_by';")" = "0" ]
}

# ---------- @with_input_artifact shorthand ----------

@test "the @with_input_artifact shorthand declares an input artifact" {
    knit_register "in_cmd_13" knit_empty "A consumer."
    @with_input_artifact "input_table:file" "The table to read."
    knit_done
    _knit_set_find "_KNIT_CMD_in_cmd_13_required" "input_table"
    [ "${_KNIT_CMD_in_cmd_13_input_artifact_input_table}" = "file" ]
}

# ---------- describe / --help surfacing ----------

@test "_knit_input_artifact_param_kind reads the declared kind, empty for a plain param" {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "plot" _plot "Plot."
    knit_with_input_artifact "input_table:csvfile" "The table to plot."
    knit_with_required "title:string" "A title."
    _plot() { :; }
    knit_done
    local cmd akind
    cmd=$(_knit_command_mangle "plot")
    _knit_input_artifact_param_kind akind "${cmd}" "input_table"
    [ "${akind}" = "csvfile" ]
    _knit_input_artifact_param_kind akind "${cmd}" "title"
    [ -z "${akind}" ]
}

@test "--help annotates an input-artifact parameter with its kind" {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "plot" _plot "Plot."
    knit_with_input_artifact "input_table:csvfile" "The table to plot."
    _plot() { :; }
    knit_done
    run _knit_invoke_command "plot" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"[required, artifact: csvfile]"* ]]
}

@test "describe default shows the artifact kind on the parameter line" {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "plot" _plot "Plot."
    knit_with_input_artifact "input_table:csvfile" "The table to plot."
    _plot() { :; }
    knit_done
    run knit describe --format default --only plot
    [ "$status" -eq 0 ]
    [[ "$output" == *"artifact: csvfile"* ]]
}

@test "describe json includes an artifact field for an input-artifact parameter" {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "plot" _plot "Plot."
    knit_with_input_artifact "input_table:csvfile" "The table to plot."
    _plot() { :; }
    knit_done
    run knit describe --format json --only plot
    [ "$status" -eq 0 ]
    [[ "$output" == *'"artifact": "csvfile"'* ]]
}

@test "describe json omits the artifact field for a plain parameter" {
    knit_register "plot" _plot "Plot."
    knit_with_required "title:string" "A title."
    _plot() { :; }
    knit_done
    run knit describe --format json --only plot
    [ "$status" -eq 0 ]
    [[ "$output" != *'"artifact"'* ]]
}

@test "describe yaml includes an artifact field for an input-artifact parameter" {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "plot" _plot "Plot."
    knit_with_input_artifact "input_table:csvfile" "The table to plot."
    _plot() { :; }
    knit_done
    run knit describe --format yaml --only plot
    [ "$status" -eq 0 ]
    [[ "$output" == *"artifact: csvfile"* ]]
}

@test "describe markdown shows the artifact kind in the constraints column" {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "plot" _plot "Plot."
    knit_with_input_artifact "input_table:csvfile" "The table to plot."
    _plot() { :; }
    knit_done
    run knit describe --format markdown --only plot
    [ "$status" -eq 0 ]
    [[ "$output" == *'artifact: `csvfile`'* ]]
}

@test "describe reports an output artifact's kind, not its physical type" {
    knit_register_artifact "csvfile:file" "A CSV table."
    knit_register "tabulate" _tabulate "Tabulate."
    knit_with_output_artifact "table:csvfile" "The results table."
    _tabulate() { :; }
    knit_done
    run knit describe --format json --only tabulate
    [ "$status" -eq 0 ]
    [[ "$output" == *'"type": "csvfile"'* ]]
    [[ "$output" != *'"type": "file"'* ]]
}
