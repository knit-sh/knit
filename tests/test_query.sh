#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_db_setup
    # Reset the live table registry so each test controls the alias map.
    _KNIT_DB_REGISTERED_TABLES=()
}

teardown() {
    knit_test_db_teardown
}

# ---------- _knit_query_read_output_opts ----------

@test "read output opts applies defaults (list, header off, empty separator)" {
    local fmt hdr sep
    _knit_query_read_output_opts fmt hdr sep
    [ "${fmt}" = "list" ]
    [ "${hdr}" = "false" ]
    [ -z "${sep}" ]
}

@test "read output opts reads provided --format/--header/--separator" {
    local fmt hdr sep
    _knit_query_read_output_opts fmt hdr sep \
        --format json --header true --separator ","
    [ "${fmt}" = "json" ]
    [ "${hdr}" = "true" ]
    [ "${sep}" = "," ]
}

@test "read output opts keeps header off when the flag is absent" {
    local fmt hdr sep
    _knit_query_read_output_opts fmt hdr sep --format csv
    [ "${fmt}" = "csv" ]
    [ "${hdr}" = "false" ]
}

# ---------- _knit_query_table_alias ----------

@test "table alias is the command name when it differs from the table" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")
    local alias
    _knit_query_table_alias alias "jobs"
    [ "${alias}" = "submit" ]
}

@test "table alias is empty when the table equals its command name" {
    _KNIT_DB_REGISTERED_TABLES=([setup:libs]="setup:libs")
    local alias
    _knit_query_table_alias alias "setup:libs"
    [ -z "${alias}" ]
}

@test "table alias is empty for an unregistered table" {
    local alias
    _knit_query_table_alias alias "nosuchtable"
    [ -z "${alias}" ]
}

# ---------- _knit_query_annotate_catalog ----------

@test "annotate catalog appends command aliases and passes columns through" {
    _KNIT_DB_REGISTERED_TABLES=(
        [jobs]="submit" [montecarlo]="submit:montecarlo" [setup:libs]="setup:libs"
    )
    run _knit_query_annotate_catalog <<'EOF'
table jobs
  column id
  column state
table montecarlo
  column id
table setup:libs
  column id
EOF
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "table jobs (command: submit)" ]]
    [[ "${lines[1]}" == "  column id" ]]
    [[ "${lines[2]}" == "  column state" ]]
    [[ "${lines[3]}" == "table montecarlo (command: submit:montecarlo)" ]]
    [[ "${lines[5]}" == "table setup:libs" ]]
}

@test "annotate catalog passes a TABLE.COLUMN validation line through unchanged" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")
    run _knit_query_annotate_catalog <<'EOF'
jobs.state
EOF
    [ "$status" -eq 0 ]
    [ "${output}" = "jobs.state" ]
}

# ---------- knit query catalog ----------

@test "query catalog forwards --catalog and the database, and annotates" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    # Stub the knit-graph resolver: record its argv and emit a fake catalog.
    _knit_knit_graph() {
        printf '%s\n' "$*" > "${argfile}"
        printf 'table jobs\n  column id\n'
    }
    run knit query catalog
    [ "$status" -eq 0 ]
    [ "$(cat "${argfile}")" = "--catalog ${_KNIT_DATABASE}" ]
    [[ "${lines[0]}" == "table jobs (command: submit)" ]]
    [[ "${lines[1]}" == "  column id" ]]
}

@test "query catalog forwards a TABLE reference passed after --" {
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() {
        printf '%s\n' "$*" > "${argfile}"
        printf 'table montecarlo\n  column id\n'
    }
    run knit query catalog -- montecarlo
    [ "$status" -eq 0 ]
    [ "$(cat "${argfile}")" = "--catalog ${_KNIT_DATABASE} montecarlo" ]
}

@test "query catalog propagates knit-graph's non-zero exit" {
    _knit_knit_graph() { return 3; }
    run knit query catalog -- nosuchtable
    [ "$status" -eq 3 ]
}

# ---------- _knit_query_build_names ----------

@test "build names emits a sorted table=command SPEC" {
    _KNIT_DB_REGISTERED_TABLES=(
        [jobs]="submit" [montecarlo]="submit:montecarlo" [setup:libs]="setup:libs"
    )
    local spec
    _knit_query_build_names spec
    [ "${spec}" = "jobs=submit
montecarlo=submit:montecarlo
setup:libs=setup:libs" ]
}

@test "build names is empty when no table is registered" {
    local spec="unset"
    _knit_query_build_names spec
    [ -z "${spec}" ]
}

# ---------- _knit_query_graph_output_flags ----------

@test "graph output flags map format to -<mode> and default header off" {
    local -a flags
    _knit_query_graph_output_flags flags "list" "false" ""
    [ "${flags[*]}" = "-list -noheader" ]
}

@test "graph output flags emit -header and -separator when requested" {
    local -a flags
    _knit_query_graph_output_flags flags "json" "true" ","
    [ "${flags[*]}" = "-json -header -separator ," ]
}

# ---------- knit query graph ----------

@test "query graph forwards names, output flags, database and Cypher" {
    _KNIT_DB_REGISTERED_TABLES=([jobs]="submit")
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() { printf '%s\n' "$*" > "${argfile}"; }
    run knit query graph --exec "MATCH (j:\`jobs\`) RETURN j.id"
    [ "$status" -eq 0 ]
    [ "$(cat "${argfile}")" = "--names jobs=submit -list -noheader ${_KNIT_DATABASE} MATCH (j:\`jobs\`) RETURN j.id" ]
}

@test "query graph honours --format/--header/--separator" {
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() { printf '%s\n' "$*" > "${argfile}"; }
    run knit query graph --format json --header --separator ";" --exec "MATCH (n) RETURN n"
    [ "$status" -eq 0 ]
    [[ "$(cat "${argfile}")" == *"-json -header -separator ; ${_KNIT_DATABASE} MATCH (n) RETURN n" ]]
}

@test "query graph passes --explain through to knit-graph" {
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() { printf '%s\n' "$*" > "${argfile}"; }
    run knit query graph --explain --exec "MATCH (n) RETURN n"
    [ "$status" -eq 0 ]
    [[ "$(cat "${argfile}")" == "--explain "* ]]
    [[ "$(cat "${argfile}")" == *"${_KNIT_DATABASE} MATCH (n) RETURN n" ]]
}

@test "query graph --ast omits database, names and output flags" {
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() { printf '%s\n' "$*" > "${argfile}"; }
    run knit query graph --ast --exec "MATCH (n) RETURN n"
    [ "$status" -eq 0 ]
    [ "$(cat "${argfile}")" = "--ast MATCH (n) RETURN n" ]
}

@test "query graph forwards args after -- verbatim" {
    local argfile="${BATS_TEST_TMPDIR}/kg-args"
    _knit_knit_graph() { printf '%s\n' "$*" > "${argfile}"; }
    run knit query graph --exec "MATCH (n) RETURN n" -- -newline "@"
    [ "$status" -eq 0 ]
    [[ "$(cat "${argfile}")" == *"MATCH (n) RETURN n -newline @" ]]
}

@test "query graph rejects --explain together with --ast" {
    _knit_knit_graph() { return 0; }
    run knit query graph --explain --ast --exec "MATCH (n) RETURN n"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"mutually exclusive"* ]]
}

@test "query graph propagates knit-graph's non-zero exit" {
    _knit_knit_graph() { return 4; }
    run knit query graph --exec "MATCH (n) RETURN n"
    [ "$status" -eq 4 ]
}
