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

# Seed one successful history row. Args: id command invoked_json start_time.
_seed() {
    local id="$1" command="$2" invoked="$3" start="$4"
    _seedx "${id}" "${command}" "${invoked}" "${start}" 0
}

# Seed one history row with an explicit exit status.
# Args: id command invoked_json start_time exit_status.
_seedx() {
    local id="$1" command="$2" invoked="$3" start="$4" ex="$5"
    _knit_sqlite3_write \
        "INSERT INTO __history__ (id, command, invoked, resolved, start_time, end_time, exit_status)
         VALUES ('${id}', '${command}', '${invoked}', '${invoked}', ${start}, ${start}, ${ex});"
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

# ---------- json format (M4) ----------

@test "json format emits name/args/extra objects in time order" {
    _seed "id-1" "setup"  '["--name","base","--","somesetup"]' 1.0
    _seed "id-2" "submit" '["--nodes","4"]'                    2.0

    run knit history show --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq 'length')" -eq 2 ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].name')" = "setup" ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].args.name')" = "base" ]
    [ "$(printf '%s' "${output}" | jq -c '.[0].extra')" = '["somesetup"]' ]
    [ "$(printf '%s' "${output}" | jq -r '.[1].name')" = "submit" ]
    [ "$(printf '%s' "${output}" | jq -r '.[1].args.nodes')" = "4" ]
    [ "$(printf '%s' "${output}" | jq -c '.[1].extra')" = '[]' ]
}

@test "json name uses colon notation for a nested command" {
    _seed "id-1" "submit:drain" '["--group","mc"]' 1.0
    run knit history show --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].name')" = "submit:drain" ]
}

@test "json renders a declared flag as a boolean" {
    knit_register "flagcmd" _h_flag "F."
    knit_with_flag "verbose" "V."
    _h_flag() { :; }
    knit_done

    _seed "id-1" "flagcmd" '["--verbose","true"]' 1.0
    run knit history show --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].args.verbose')" = "true" ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].args.verbose | type')" = "boolean" ]
}

@test "json format on an empty history is an empty array" {
    run knit history show --format json
    [ "$status" -eq 0 ]
    [ "${output}" = "[]" ]
}

# ---------- --resolved (M4) ----------

@test "--resolved renders the resolved column; default renders invoked" {
    _knit_sqlite3_write \
        "INSERT INTO __history__ (id, command, invoked, resolved, start_time, end_time, exit_status)
         VALUES ('id-1', 'submit', '[\"--nodes\",\"4\"]', '[\"--nodes\",\"4\",\"--wait\",\"false\"]', 1.0, 1.0, 0);"

    run knit history show --resolved
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "submit --nodes 4 --wait false" ]

    run knit history show
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "submit --nodes 4" ]
}

@test "--resolved with json renders the resolved args" {
    _knit_sqlite3_write \
        "INSERT INTO __history__ (id, command, invoked, resolved, start_time, end_time, exit_status)
         VALUES ('id-1', 'submit', '[\"--nodes\",\"4\"]', '[\"--nodes\",\"4\",\"--walltime\",\"1:00:00\"]', 1.0, 1.0, 0);"

    run knit history show --format json --resolved
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].args.walltime')" = "1:00:00" ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].args.nodes')" = "4" ]
}

# ---------- --status filter (M5) ----------

@test "default status shows only successful invocations" {
    _seedx "id-1" "ok1" '[]' 1.0 0
    _seedx "id-2" "bad" '[]' 2.0 1
    _seedx "id-3" "ok2" '[]' 3.0 0
    run knit history show
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "ok1" ]
    [ "${lines[1]}" = "ok2" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "--status failure shows only failed invocations" {
    _seedx "id-1" "ok1" '[]' 1.0 0
    _seedx "id-2" "bad" '[]' 2.0 1
    run knit history show --status failure
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "bad" ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "--status all shows every invocation" {
    _seedx "id-1" "ok1" '[]' 1.0 0
    _seedx "id-2" "bad" '[]' 2.0 1
    run knit history show --status all
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "an unknown (NULL) exit status is excluded from success and failure" {
    _knit_sqlite3_write \
        "INSERT INTO __history__ (id, command, invoked, resolved, start_time)
         VALUES ('id-1', 'mystery', '[]', '[]', 1.0);"
    run knit history show --status all
    [ "${#lines[@]}" -eq 1 ]
    run knit history show --status success
    [ -z "${output}" ]
    run knit history show --status failure
    [ -z "${output}" ]
}

# ---------- --command filter (M5) ----------

@test "--command matches an exact command" {
    _seedx "id-1" "setup"  '[]' 1.0 0
    _seedx "id-2" "submit" '[]' 2.0 0
    run knit history show --command submit
    [ "${lines[0]}" = "submit" ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "--command bare does not match subcommands; :* does" {
    _seedx "id-1" "submit"       '[]' 1.0 0
    _seedx "id-2" "submit:drain" '[]' 2.0 0

    run knit history show --command submit
    [ "${lines[0]}" = "submit" ]
    [ "${#lines[@]}" -eq 1 ]

    run knit history show --command "submit:*"
    [ "${lines[0]}" = "submit" ]
    [ "${lines[1]}" = "submit drain" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "--command accepts a comma-separated list" {
    _seedx "id-1" "setup"        '[]' 1.0 0
    _seedx "id-2" "submit"       '[]' 2.0 0
    _seedx "id-3" "submit:drain" '[]' 3.0 0
    _seedx "id-4" "aggregate"    '[]' 4.0 0
    run knit history show --command "setup,submit:*"
    [ "${lines[0]}" = "setup" ]
    [ "${lines[1]}" = "submit" ]
    [ "${lines[2]}" = "submit drain" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "--command :* treats an underscore literally (GLOB, not LIKE)" {
    _seedx "id-1" "sub_mit:a" '[]' 1.0 0
    _seedx "id-2" "subXmit:a" '[]' 2.0 0
    run knit history show --command "sub_mit:*"
    [ "${lines[0]}" = "sub_mit a" ]
    [ "${#lines[@]}" -eq 1 ]
}

# ---------- --since / --until (M5) ----------

@test "--since and --until filter by ISO timestamp against start_time" {
    _seedx "id-1" "old"    '[]' 1000000000 0
    _seedx "id-2" "recent" '[]' 2000000000 0

    run knit history show --since "2020-01-01"
    [ "${lines[0]}" = "recent" ]
    [ "${#lines[@]}" -eq 1 ]

    run knit history show --until "2020-01-01"
    [ "${lines[0]}" = "old" ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "--since compares a UUID value against the row id" {
    _seedx "00000000-0000-7000-8000-000000000001" "first"  '[]' 1.0 0
    _seedx "00000000-0000-7000-8000-000000000002" "second" '[]' 2.0 0
    _seedx "00000000-0000-7000-8000-000000000003" "third"  '[]' 3.0 0
    run knit history show --since "00000000-0000-7000-8000-000000000002"
    [ "${lines[0]}" = "second" ]
    [ "${lines[1]}" = "third" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "--since with an unparseable value is fatal" {
    _seedx "id-1" "x" '[]' 1.0 0
    run knit history show --since "not-a-time"
    [ "$status" -ne 0 ]
    [[ "${output}" == *"cannot parse time"* ]]
}

# ---------- --first / --last / --id (M5) ----------

@test "--first keeps the earliest N" {
    _seedx "id-1" "a" '[]' 1.0 0
    _seedx "id-2" "b" '[]' 2.0 0
    _seedx "id-3" "c" '[]' 3.0 0
    run knit history show --first 2
    [ "${lines[0]}" = "a" ]
    [ "${lines[1]}" = "b" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "--last keeps the latest N but still prints oldest-first" {
    _seedx "id-1" "a" '[]' 1.0 0
    _seedx "id-2" "b" '[]' 2.0 0
    _seedx "id-3" "c" '[]' 3.0 0
    run knit history show --last 2
    [ "${lines[0]}" = "b" ]
    [ "${lines[1]}" = "c" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "--first and --last together is an error" {
    _seedx "id-1" "a" '[]' 1.0 0
    run knit history show --first 1 --last 1
    [ "$status" -ne 0 ]
    [[ "${output}" == *"mutually exclusive"* ]]
}

@test "--id selects a single invocation" {
    _seedx "id-1" "a" '[]' 1.0 0
    _seedx "id-2" "b" '[]' 2.0 0
    run knit history show --id "id-2"
    [ "${lines[0]}" = "b" ]
    [ "${#lines[@]}" -eq 1 ]
}

# ---------- combinations and json (M5) ----------

@test "filters combine with AND (command subtree + default success)" {
    _seedx "id-1" "submit"       '[]' 1.0 0
    _seedx "id-2" "submit:drain" '[]' 2.0 1
    _seedx "id-3" "submit:drain" '[]' 3.0 0
    run knit history show --command "submit:*"
    [ "${lines[0]}" = "submit" ]
    [ "${lines[1]}" = "submit drain" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "filters apply to the json format too" {
    _seedx "id-1" "setup"  '["--name","base"]' 1.0 0
    _seedx "id-2" "submit" '["--nodes","4"]'   2.0 0
    run knit history show --command submit --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq 'length')" -eq 1 ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].name')" = "submit" ]
}

# ---------- --annotate (M6) ----------

@test "--annotate prefixes each default line with id/time/exit" {
    _seedx "the-id" "setup" '["--name","base"]' 1700000000 0
    run knit history show --annotate
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "# the-id "*"(exit 0)" ]]
    [[ "${lines[0]}" == *"2023-11-14T22:13:20Z"* ]]
    [ "${lines[1]}" = "setup --name base" ]
}

@test "--annotate in bash format comments each entry above its ./script line" {
    KNIT_SCRIPT_NAME="exp.sh"
    _seedx "the-id" "setup" '["--name","base"]' 1700000000 0
    run knit history show --format bash --annotate
    [ "${lines[0]}" = "#!/usr/bin/env bash" ]
    [[ "${lines[1]}" == "# the-id "*"(exit 0)" ]]
    [ "${lines[2]}" = "./exp.sh setup --name base" ]
}

@test "--annotate adds id/time/exit fields in json" {
    _seedx "the-id" "setup" '["--name","base"]' 1700000000 0
    run knit history show --format json --annotate
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].id')" = "the-id" ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].exit')" = "0" ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].time')" = "2023-11-14T22:13:20Z" ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].name')" = "setup" ]
}

@test "without --annotate the json objects carry no id/time/exit" {
    _seed "id-1" "setup" '[]' 1.0
    run knit history show --format json
    [ "$(printf '%s' "${output}" | jq -r '.[0] | has("id")')" = "false" ]
    [ "$(printf '%s' "${output}" | jq -r '.[0] | has("time")')" = "false" ]
    [ "$(printf '%s' "${output}" | jq -r '.[0] | has("exit")')" = "false" ]
}

@test "--annotate shows '?' and json null for an unknown exit status" {
    _knit_sqlite3_write \
        "INSERT INTO __history__ (id, command, invoked, resolved, start_time)
         VALUES ('mystery-id', 'x', '[]', '[]', 1700000000);"
    run knit history show --annotate --status all
    [[ "${lines[0]}" == *"(exit ?)" ]]
    run knit history show --format json --annotate --status all
    [ "$(printf '%s' "${output}" | jq -r '.[0].exit')" = "null" ]
}

# ---------- --output (M6) ----------

@test "--output writes to a file and prints nothing to stdout" {
    _seed "id-1" "setup" '["--name","base"]' 1.0
    local f; f="$(mktemp)"
    run knit history show --output "${f}"
    [ "$status" -eq 0 ]
    [ -z "${output}" ]
    [ "$(cat "${f}")" = "setup --name base" ]
    rm -f "${f}"
}

@test "--output with bash format writes a runnable replay script" {
    KNIT_SCRIPT_NAME="exp.sh"
    _seed "id-1" "setup"  '["--name","base"]' 1.0
    _seed "id-2" "submit" '["--nodes","4"]'   2.0
    local f; f="$(mktemp)"
    run knit history show --format bash --output "${f}"
    [ "$status" -eq 0 ]
    [ -z "${output}" ]
    [ "$(head -1 "${f}")" = "#!/usr/bin/env bash" ]
    grep -qx "./exp.sh setup --name base" "${f}"
    grep -qx "./exp.sh submit --nodes 4" "${f}"
    rm -f "${f}"
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
