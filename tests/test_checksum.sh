#!/usr/bin/env bats

# Runtime existence checks and content checksums for file/directory parameters
# and outputs of single-process commands (the non-app path). See src/cli.sh
# (_knit_checksum_inputs / _knit_checksum_outputs / _knit_checksum_require_exists).

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# Read one column of the single recorded row of a table.
_col() {
    sqlite3 "${_KNIT_DATABASE}" "SELECT ${1} FROM '${2}';"
}

# True when a table has a column of the given name.
_has_col() {
    sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('${1}');" | grep -q "|${2}|"
}

# ---------- inputs ----------

@test "a present file input records its path and sha256: digest" {
    local f="${BATS_TEST_TMPDIR}/in.txt"
    printf 'hello\n' > "${f}"
    knit_register "cs_in" fn_cs_in "Test."
    knit_with_table
    knit_with_required "data:file" "The input."
    fn_cs_in() { :; }
    knit_done
    _knit_invoke_command "cs_in" "--data" "${f}"
    [ "$(_col data cs_in)" = "${f}" ]
    local expected
    _knit_sha256 expected "${f}"
    [ "$(_col data_checksum cs_in)" = "sha256:${expected}" ]
}

@test "a missing required file input is fatal before the body runs" {
    local ran="${BATS_TEST_TMPDIR}/ran"
    knit_register "cs_in_miss" fn_cs_in_miss "Test."
    knit_with_table
    knit_with_required "data:file" "The input."
    fn_cs_in_miss() { touch "${ran}"; }
    knit_done
    run _knit_invoke_command "cs_in_miss" "--data" "${BATS_TEST_TMPDIR}/nope.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
    [ ! -e "${ran}" ]
}

@test "an absent optional file input records an empty checksum" {
    knit_register "cs_opt" fn_cs_opt "Test."
    knit_with_table
    knit_with_optional "data:file" "" "The input."
    fn_cs_opt() { :; }
    knit_done
    _knit_invoke_command "cs_opt"
    [ "$(_col data cs_opt)" = "" ]
    [ "$(_col data_checksum cs_opt)" = "" ]
}

@test "an optional file input given a missing path is fatal" {
    knit_register "cs_opt_miss" fn_cs_opt_miss "Test."
    knit_with_table
    knit_with_optional "data:file" "" "The input."
    fn_cs_opt_miss() { :; }
    knit_done
    run _knit_invoke_command "cs_opt_miss" "--data" "${BATS_TEST_TMPDIR}/nope.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "a directory input is hashed recursively" {
    local d="${BATS_TEST_TMPDIR}/tree"
    mkdir -p "${d}/sub"
    printf 'a\n' > "${d}/a.txt"
    printf 'b\n' > "${d}/sub/b.txt"
    knit_register "cs_din" fn_cs_din "Test."
    knit_with_table
    knit_with_required "data:directory" "The input tree."
    fn_cs_din() { :; }
    knit_done
    _knit_invoke_command "cs_din" "--data" "${d}"
    local expected
    _knit_sha256 expected "${d}"
    [ "$(_col data_checksum cs_din)" = "sha256:${expected}" ]
}

@test "the input digest reflects the artifact as consumed, not as the body leaves it" {
    local f="${BATS_TEST_TMPDIR}/mut.txt"
    printf 'before\n' > "${f}"
    local expected
    _knit_sha256 expected "${f}"
    knit_register "cs_mut" fn_cs_mut "Test."
    knit_with_table
    knit_with_required "data:file" "The input."
    fn_cs_mut() { printf 'after-and-longer\n' > "${f}"; }
    knit_done
    _knit_invoke_command "cs_mut" "--data" "${f}"
    [ "$(_col data_checksum cs_mut)" = "sha256:${expected}" ]
}

# ---------- outputs ----------

@test "a present file output records its digest" {
    local f="${BATS_TEST_TMPDIR}/out.txt"
    knit_register "cs_out" fn_cs_out "Test."
    knit_with_table
    knit_with_output "result:file" "" "The output."
    fn_cs_out() { printf 'produced\n' > "${f}"; knit_output "result" "${f}"; }
    knit_done
    _knit_invoke_command "cs_out"
    [ "$(_col result cs_out)" = "${f}" ]
    local expected
    _knit_sha256 expected "${f}"
    [ "$(_col result_checksum cs_out)" = "sha256:${expected}" ]
}

@test "a declared output missing on a successful completion is fatal" {
    knit_register "cs_out_miss" fn_cs_out_miss "Test."
    knit_with_table
    knit_with_output "result:file" "" "The output."
    fn_cs_out_miss() { knit_output "result" "${BATS_TEST_TMPDIR}/never.txt"; }
    knit_done
    run _knit_invoke_command "cs_out_miss"
    [ "$status" -ne 0 ]
    [[ "$output" == *"was not produced"* ]]
}

@test "a directory output is hashed recursively" {
    local d="${BATS_TEST_TMPDIR}/otree"
    knit_register "cs_dout" fn_cs_dout "Test."
    knit_with_table
    knit_with_output "result:directory" "" "The output tree."
    fn_cs_dout() {
        mkdir -p "${d}/sub"
        printf 'x\n' > "${d}/x.txt"
        printf 'y\n' > "${d}/sub/y.txt"
        knit_output "result" "${d}"
    }
    knit_done
    _knit_invoke_command "cs_dout"
    local expected
    _knit_sha256 expected "${d}"
    [ "$(_col result_checksum cs_dout)" = "sha256:${expected}" ]
}

@test "output existence is not checked when the body fails" {
    knit_register "cs_fail" fn_cs_fail "Test."
    knit_with_table
    knit_with_output "result:file" "" "The output."
    fn_cs_fail() { return 3; }
    knit_done
    run _knit_invoke_command "cs_fail"
    [ "$status" -eq 3 ]
    [[ "$output" != *"was not produced"* ]]
    # The row is still recorded (no knit_no_record_on_failure), with an empty
    # output path and checksum.
    [ "$(_col result cs_fail)" = "" ]
    [ "$(_col result_checksum cs_fail)" = "" ]
}

# ---------- --no-checksum ----------

@test "--no-checksum records the path with no checksum column" {
    local f="${BATS_TEST_TMPDIR}/plain.txt"
    printf 'data\n' > "${f}"
    knit_register "cs_no" fn_cs_no "Test."
    knit_with_table
    knit_with_required "data:file" "The input." --no-checksum
    fn_cs_no() { :; }
    knit_done
    _knit_invoke_command "cs_no" "--data" "${f}"
    [ "$(_col data cs_no)" = "${f}" ]
    _has_col cs_no data
    ! _has_col cs_no data_checksum
}

@test "--no-checksum still validates input existence" {
    knit_register "cs_no_miss" fn_cs_no_miss "Test."
    knit_with_table
    knit_with_required "data:file" "The input." --no-checksum
    fn_cs_no_miss() { :; }
    knit_done
    run _knit_invoke_command "cs_no_miss" "--data" "${BATS_TEST_TMPDIR}/nope.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
}
