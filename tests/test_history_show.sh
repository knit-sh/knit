#!/usr/bin/env bats

# History show (M3): "knit history show" prints the recorded top-level user
# invocations in time order, as "default" one-liners or a "bash" replay script.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup
    # Enum-typed --format evaluates its constraint via jq; the show body also
    # parses the stored JSON token arrays with jq.
    _KNIT_JQ_EXE="jq"
    _knit_history_create_table
}

teardown() {
    knit_test_db_teardown
}

# Seed one history row. Args: id command invoked_json start_time.
_seed() {
    local id="$1" command="$2" invoked="$3" start="$4"
    _knit_sqlite3_write \
        "INSERT INTO __history__ (id, command, invoked, resolved, start_time, end_time, exit_status)
         VALUES ('${id}', '${command}', '${invoked}', '${invoked}', ${start}, ${start}, 0);"
}

# ---------- default format ----------

@test "default format lists invocations in time order" {
    _seed "id-1" "setup"     '["--name","base"]' 1.0
    _seed "id-2" "submit"    '["--nodes","4"]'   2.0
    _seed "id-3" "aggregate" '[]'                3.0

    run knit history show
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "setup --name base" ]
    [ "${lines[1]}" = "submit --nodes 4" ]
    [ "${lines[2]}" = "aggregate" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "default is the format when none is given, and --format default is explicit" {
    _seed "id-1" "aggregate" '[]' 1.0
    run knit history show --format default
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "aggregate" ]
}

@test "a nested command name renders with colons turned to spaces" {
    _seed "id-1" "submit:drain" '["--group","mc"]' 1.0
    run knit history show
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "submit drain --group mc" ]
}

@test "a token that needs quoting is minimally quoted" {
    _seed "id-1" "run" '["--msg","hello world"]' 1.0
    run knit history show
    [ "$status" -eq 0 ]
    # _knit_str_render_cmd uses printf %q: a space is backslash-escaped.
    [ "${lines[0]}" = 'run --msg hello\ world' ]
}

@test "the dispatched tail after -- is rendered verbatim" {
    _seed "id-1" "setup" '["--name","base","--","somesetup","--opt","1"]' 1.0
    run knit history show
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "setup --name base -- somesetup --opt 1" ]
}

# ---------- bash format ----------

@test "bash format emits a shebang then ./<script> lines" {
    KNIT_SCRIPT_NAME="exp.sh"
    _seed "id-1" "setup"  '["--name","base"]' 1.0
    _seed "id-2" "submit" '["--nodes","4"]'   2.0

    run knit history show --format bash
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "#!/usr/bin/env bash" ]
    [ "${lines[1]}" = "./exp.sh setup --name base" ]
    [ "${lines[2]}" = "./exp.sh submit --nodes 4" ]
    [ "${#lines[@]}" -eq 3 ]
}

# ---------- empty history ----------

@test "an empty history prints nothing in default format" {
    run knit history show
    [ "$status" -eq 0 ]
    [ -z "${output}" ]
}

@test "an empty history prints only the shebang in bash format" {
    run knit history show --format bash
    [ "$status" -eq 0 ]
    [ "${output}" = "#!/usr/bin/env bash" ]
}

# ---------- ordering ----------

@test "rows are ordered by start_time regardless of insertion order" {
    _seed "id-b" "second" '[]' 2.0
    _seed "id-c" "third"  '[]' 3.0
    _seed "id-a" "first"  '[]' 1.0

    run knit history show
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "first" ]
    [ "${lines[1]}" = "second" ]
    [ "${lines[2]}" = "third" ]
}

# ---------- registration / no self-recording ----------

@test "history show does not record itself into the history" {
    _seed "id-1" "aggregate" '[]' 1.0
    run knit history show
    [ "$status" -eq 0 ]
    # Still exactly the one seeded row: show is knit_without_provenance.
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM __history__;")" -eq 1 ]
}

# ---------- end to end: capture (M2) then show (M3) ----------

@test "a real invocation is captured and then shown as invoked" {
    knit_register "demo" _h_demo "Demo."
    knit_with_optional "size:integer" "10" "Size."
    _h_demo() { :; }
    knit_done

    _knit_invoke_command "demo" --size 7

    run knit history show
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "demo --size 7" ]
    [ "${#lines[@]}" -eq 1 ]
}
