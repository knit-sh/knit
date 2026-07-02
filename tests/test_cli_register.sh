#!/usr/bin/env bats

setup() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi

    source knit.sh

    # Override the sqlite executable and database path for testing
    __KNIT_SQLITE_EXE="sqlite3"
    __KNIT_DATABASE="$(mktemp --suffix=.db)"

    # Satisfy the bootstrap check — tests in this file work with a live DB
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    rm -f "${__KNIT_DATABASE}"
    _KNIT_IS_BOOTSTRAPPED=""
}

# ---------- knit_register / knit_done ----------

@test "knit_register adds command to registry" {
    knit_register knit_empty "reg_cmd" "A registered command."
    knit_done
    _knit_set_find _KNIT_COMMANDS "reg_cmd"
}

@test "knit_register fails with invalid character in command name" {
    run knit_register knit_empty "my cmd" "Bad command."
    [ "$status" -eq 1 ]
}

@test "knit_register fails if parent command not registered" {
    run knit_register knit_empty "parent:child" "Child command."
    [ "$status" -eq 1 ]
}

@test "knit_register fails if command already registered" {
    knit_register knit_empty "dup_cmd" "First registration."
    knit_done
    run knit_register knit_empty "dup_cmd" "Second registration."
    [ "$status" -eq 1 ]
}

@test "knit_register allows subcommand when parent is registered" {
    knit_register knit_empty "par_cmd" "Parent command."
    knit_done
    knit_register knit_empty "par_cmd:sub" "Subcommand."
    knit_done
    _knit_set_find _KNIT_COMMANDS "par_cmd__1__sub"
}

@test "knit_done fails if registered function is not defined" {
    knit_register undefined_fn "undef_cmd" "Test."
    run knit_done
    [ "$status" -eq 1 ]
}

# ---------- __knit_push_done_cb ----------

@test "__knit_push_done_cb fails outside of knit_register" {
    run __knit_push_done_cb echo "hello"
    [ "$status" -eq 1 ]
}

@test "__knit_push_done_cb callback is invoked at knit_done" {
    _KNIT_PDC_CALLED=false
    _pdc_mark_called() { _KNIT_PDC_CALLED=true; }
    pdc_fn_a() { :; }
    knit_register pdc_fn_a "pdc_a" "Test."
    __knit_push_done_cb _pdc_mark_called
    knit_done
    [ "${_KNIT_PDC_CALLED}" = "true" ]
}

@test "__knit_push_done_cb multiple callbacks run in reverse order" {
    declare -ga _KNIT_PDC_ORDER=()
    _pdc_order_append() { _KNIT_PDC_ORDER+=("$1"); }
    pdc_fn_b() { :; }
    knit_register pdc_fn_b "pdc_b" "Test."
    __knit_push_done_cb _pdc_order_append "first"
    __knit_push_done_cb _pdc_order_append "second"
    __knit_push_done_cb _pdc_order_append "third"
    knit_done
    [ "${_KNIT_PDC_ORDER[0]}" = "third" ]
    [ "${_KNIT_PDC_ORDER[1]}" = "second" ]
    [ "${_KNIT_PDC_ORDER[2]}" = "first" ]
}

@test "__knit_push_done_cb _KNIT_DONE_CBS is unset after knit_done" {
    pdc_fn_c() { :; }
    knit_register pdc_fn_c "pdc_c" "Test."
    __knit_push_done_cb echo "cb"
    knit_done
    [[ ! -v _KNIT_DONE_CBS ]]
}

@test "__knit_push_done_cb callbacks do not carry over to next registration" {
    _KNIT_PDC_COUNT=0
    _pdc_increment() { _KNIT_PDC_COUNT=$(( _KNIT_PDC_COUNT + 1 )); }
    pdc_fn_d() { :; }
    knit_register pdc_fn_d "pdc_d" "Test."
    __knit_push_done_cb _pdc_increment
    pdc_fn_e() { :; }
    knit_register pdc_fn_e "pdc_e" "Test."
    # implicit knit_done fired for pdc_d: count becomes 1
    knit_done
    # explicit knit_done for pdc_e: no callbacks pushed, count stays 1
    [ "${_KNIT_PDC_COUNT}" -eq 1 ]
}

# ---------- knit_hidden ----------

@test "knit_hidden marks a command as hidden" {
    knit_register knit_empty "hid_cmd" "A hidden command."
    knit_hidden
    knit_done
    [ "${_KNIT_CMD_hid_cmd_is_hidden}" = "true" ]
}

@test "knit_hidden fails outside of knit_register" {
    run knit_hidden
    [ "$status" -eq 1 ]
}

# ---------- knit_with_subcommand_title ----------

@test "knit_with_subcommand_title sets the subcommand title" {
    knit_register knit_empty "sct_cmd" "Test."
    knit_with_subcommand_title "My Operations"
    knit_done
    [ "${_KNIT_CMD_sct_cmd_sucommand_title}" = "My Operations" ]
}

@test "knit_with_subcommand_title fails outside of knit_register" {
    run knit_with_subcommand_title "title"
    [ "$status" -eq 1 ]
}

# ---------- knit_with_flag ----------

@test "knit_with_flag registers a flag" {
    knit_register knit_empty "flg_cmd" "Test."
    knit_with_flag "verbose" "Enable verbose output."
    knit_done
    _knit_set_find "_KNIT_CMD_flg_cmd_flags" "verbose"
}

@test "knit_with_flag normalizes hyphens to underscores" {
    knit_register knit_empty "flg_cmd2" "Test."
    knit_with_flag "dry-run" "Dry run mode."
    knit_done
    _knit_set_find "_KNIT_CMD_flg_cmd2_flags" "dry_run"
}

@test "knit_with_flag fails outside of knit_register" {
    run knit_with_flag "verbose" "Enable verbose output."
    [ "$status" -eq 1 ]
}

@test "knit_with_flag rejects invalid flag name" {
    knit_register knit_empty "flg_cmd3" "Test."
    run knit_with_flag "invalid name" "Has a space."
    [ "$status" -eq 1 ]
}

# ---------- knit_with_extra ----------

@test "knit_with_extra stores the extra description" {
    knit_register knit_empty "ext_cmd" "Test."
    knit_with_extra "Extra arguments passed after --."
    knit_done
    [ "${_KNIT_CMD_ext_cmd_extra}" = "Extra arguments passed after --." ]
}

@test "knit_with_extra fails outside of knit_register" {
    run knit_with_extra "Extra args."
    [ "$status" -eq 1 ]
}

# ---------- __knit_param_check_declaration (edge cases) ----------

@test "knit_with_required fails outside of knit_register" {
    run knit_with_required "name:string" "A name."
    [ "$status" -eq 1 ]
}

@test "knit_with_required rejects invalid parameter name" {
    knit_register knit_empty "inv_cmd" "Test."
    run knit_with_required "invalid name:string" "A name."
    [ "$status" -eq 1 ]
}

@test "knit_with_required rejects duplicate parameter name" {
    knit_register knit_empty "dup_param_cmd" "Test."
    knit_with_required "name:string" "First declaration."
    run knit_with_required "name:string" "Duplicate."
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_optional fails outside of knit_register" {
    run knit_with_optional "name:string" "default" "A name."
    [ "$status" -eq 1 ]
}

# ---------- _knit_run_before / _knit_run_after ----------

@test "_knit_run_before registers a before callback" {
    knit_register knit_empty "rb_cmd" "Test."
    _knit_run_before echo "before_output"
    knit_done
    [ "${#_KNIT_CMD_rb_cmd_before_cb[@]}" -eq 1 ]
}

@test "_knit_run_before fails outside of knit_register" {
    run _knit_run_before echo "before"
    [ "$status" -eq 1 ]
}

@test "_knit_run_after registers an after callback" {
    knit_register knit_empty "ra_cmd" "Test."
    _knit_run_after echo "after_output"
    knit_done
    [ "${#_KNIT_CMD_ra_cmd_after_cb[@]}" -eq 1 ]
}

@test "_knit_run_after fails outside of knit_register" {
    run _knit_run_after echo "after"
    [ "$status" -eq 1 ]
}

# ---------- __knit_execute_before_commands / __knit_execute_after_commands ----------

@test "__knit_execute_before_commands executes registered callbacks" {
    knit_register knit_empty "eb_cmd" "Test."
    _knit_run_before echo "before_output"
    knit_done
    local result
    result=$(__knit_execute_before_commands "eb_cmd")
    [ "$result" = "before_output" ]
}

@test "__knit_execute_before_commands does nothing when no callbacks registered" {
    knit_register knit_empty "eb_cmd2" "Test."
    knit_done
    local result
    result=$(__knit_execute_before_commands "eb_cmd2")
    [ -z "$result" ]
}

@test "__knit_execute_after_commands executes registered callbacks" {
    knit_register knit_empty "ea_cmd" "Test."
    _knit_run_after echo "after_output"
    knit_done
    local result
    result=$(__knit_execute_after_commands "ea_cmd")
    [ "$result" = "after_output" ]
}

@test "__knit_execute_after_commands does nothing when no callbacks registered" {
    knit_register knit_empty "ea_cmd2" "Test."
    knit_done
    local result
    result=$(__knit_execute_after_commands "ea_cmd2")
    [ -z "$result" ]
}

# ---------- __knit_find_flag ----------

@test "__knit_find_flag returns 0 when flag is present" {
    __knit_find_flag "--verbose" "aaa" "--verbose" "bbb"
}

@test "__knit_find_flag returns 1 when flag is absent" {
    run __knit_find_flag "--verbose" "aaa" "bbb"
    [ "$status" -eq 1 ]
}

@test "__knit_find_flag stops searching after double dash" {
    run __knit_find_flag "--verbose" "aaa" "--" "--verbose"
    [ "$status" -eq 1 ]
}

@test "__knit_find_flag matches hyphen and underscore variants" {
    __knit_find_flag "--dry-run" "--dry_run"
    __knit_find_flag "--dry_run" "--dry-run"
}

