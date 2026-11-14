#!/usr/bin/env bats

# History capture (M2): a top-level user invocation (a root, with no provenance
# source) of a provenance-participating command records one __history__ row with
# its as-invoked and as-resolved argument forms. Nested, cross-process, hidden,
# without-provenance, and recording-disabled invocations record nothing.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup
    _KNIT_JQ_EXE="$(command -v jq || true)"
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    _KNIT_RECORDING_SUPPRESSED=""
    _knit_history_create_table
}

teardown() {
    knit_test_db_teardown
}

_hcount() {
    sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM __history__;"
}

# ---------- a root invocation is recorded ----------

@test "a root command records exactly one history row" {
    knit_register "rootcmd" _h_root_fn "Root."
    _h_root_fn() { :; }
    knit_done

    _knit_invoke_command "rootcmd"

    [ "$(_hcount)" -eq 1 ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT command FROM __history__;")" = "rootcmd" ]
}

@test "the row records the invoked and resolved argument forms" {
    knit_register "argcmd" _h_arg_fn "Args."
    knit_with_optional "size:integer" "10" "Size."
    knit_with_flag "verbose" "Verbose."
    _h_arg_fn() { :; }
    knit_done

    # --size is left default; --verbose is left off. Invoked keeps them absent;
    # resolved pins the default and normalizes the flag.
    _knit_invoke_command "argcmd"

    local invoked resolved
    invoked=$(sqlite3 "${_KNIT_DATABASE}" "SELECT invoked FROM __history__;")
    resolved=$(sqlite3 "${_KNIT_DATABASE}" "SELECT resolved FROM __history__;")
    [ "${invoked}" = '[]' ]
    # Resolved carries the injected default and the normalized flag.
    [ "$(printf '%s' "${resolved}" | jq -r 'index("--size")')" != "null" ]
    [ "$(printf '%s' "${resolved}" | jq -r '.[(index("--size"))+1]')" = "10" ]
    [ "$(printf '%s' "${resolved}" | jq -r '.[(index("--verbose"))+1]')" = "false" ]
}

@test "the invoked form keeps exactly the tokens the user typed" {
    knit_register "typedcmd" _h_typed_fn "Typed."
    knit_with_optional "size:integer" "10" "Size."
    _h_typed_fn() { :; }
    knit_done

    _knit_invoke_command "typedcmd" --size 42

    local invoked
    invoked=$(sqlite3 "${_KNIT_DATABASE}" "SELECT invoked FROM __history__;")
    [ "${invoked}" = '["--size","42"]' ]
}

@test "the extra tail after -- survives in both forms" {
    knit_register "dispcmd" _h_disp_fn "Disp."
    knit_with_optional "name:string" "base" "Name."
    knit_with_extra "A child and its args."
    _h_disp_fn() { :; }
    knit_done

    _knit_invoke_command "dispcmd" --name foo -- child --opt 1

    local invoked resolved
    invoked=$(sqlite3 "${_KNIT_DATABASE}" "SELECT invoked FROM __history__;")
    resolved=$(sqlite3 "${_KNIT_DATABASE}" "SELECT resolved FROM __history__;")
    # The dispatched tail is present and untouched in both.
    [ "$(printf '%s' "${invoked}"  | jq -c '.[-3:]')" = '["child","--opt","1"]' ]
    [ "$(printf '%s' "${resolved}" | jq -c '.[-3:]')" = '["child","--opt","1"]' ]
}

# ---------- what is NOT recorded ----------

@test "a nested in-process call records no history row" {
    knit_register "nchild" _h_nchild_fn "Child."
    _h_nchild_fn() { :; }
    knit_done
    knit_register "nparent" _h_nparent_fn "Parent."
    _h_nparent_fn() { _knit_invoke_command "nchild"; }
    knit_done

    _knit_invoke_command "nparent"

    # Only the parent (the root) is recorded; the child is not.
    [ "$(_hcount)" -eq 1 ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT command FROM __history__;")" = "nparent" ]
}

@test "a cross-process call (KNIT_SOURCE_ID set) records no history row" {
    knit_register "xcmd" _h_x_fn "X."
    _h_x_fn() { :; }
    knit_done

    KNIT_SOURCE_ID="parent-id" KNIT_SOURCE_COMMAND="submit" \
        _knit_invoke_command "xcmd"

    [ "$(_hcount)" -eq 0 ]
}

@test "a hidden command records no history row" {
    knit_register "hidcmd" _h_hid_fn "Hidden."
    knit_hidden
    _h_hid_fn() { :; }
    knit_done

    _knit_invoke_command "hidcmd"

    [ "$(_hcount)" -eq 0 ]
}

@test "a knit_without_provenance command records no history row" {
    knit_register "nopcmd" _h_nop_fn "No prov."
    knit_without_provenance
    _h_nop_fn() { :; }
    knit_done

    _knit_invoke_command "nopcmd"

    [ "$(_hcount)" -eq 0 ]
}

@test "KNIT_DISABLE_RECORDING suppresses the history row" {
    knit_register "dcmd" _h_d_fn "D."
    _h_d_fn() { :; }
    knit_done

    KNIT_DISABLE_RECORDING=true _knit_invoke_command "dcmd"

    [ "$(_hcount)" -eq 0 ]
}

@test "a recording-suppressed rank records no history row" {
    knit_register "scmd" _h_s_fn "S."
    _h_s_fn() { :; }
    knit_done

    _KNIT_RECORDING_SUPPRESSED="1"
    _knit_invoke_command "scmd"
    _KNIT_RECORDING_SUPPRESSED=""

    [ "$(_hcount)" -eq 0 ]
}

# ---------- exit status ----------

@test "a failed root records a row with its non-zero exit status" {
    knit_register "failcmd" _h_fail_fn "Fail."
    _h_fail_fn() { return 3; }
    knit_done

    _knit_invoke_command "failcmd" || true

    [ "$(_hcount)" -eq 1 ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT exit_status FROM __history__;")" = "3" ]
}

@test "a successful root records exit status 0" {
    knit_register "okcmd" _h_ok_fn "Ok."
    _h_ok_fn() { :; }
    knit_done

    _knit_invoke_command "okcmd"

    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT exit_status FROM __history__;")" = "0" ]
}

# ---------- time ordering ----------

@test "rows carry start and end times ordered by start_time" {
    knit_register "t1cmd" _h_t1_fn "T1."
    _h_t1_fn() { :; }
    knit_done
    knit_register "t2cmd" _h_t2_fn "T2."
    _h_t2_fn() { :; }
    knit_done

    _knit_invoke_command "t1cmd"
    _knit_invoke_command "t2cmd"

    local ordered
    ordered=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT command FROM __history__ ORDER BY start_time, id;" | tr '\n' ',')
    [ "${ordered}" = "t1cmd,t2cmd," ]
    # Both timestamps are present (not NULL).
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM __history__ WHERE start_time IS NOT NULL AND end_time IS NOT NULL;")" -eq 2 ]
}
