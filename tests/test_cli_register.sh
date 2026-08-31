#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- knit_register / knit_done ----------

@test "knit_register adds command to registry" {
    knit_register "reg_cmd" knit_empty "A registered command."
    knit_done
    _knit_set_find _KNIT_COMMANDS "reg_cmd"
}

@test "knit_register fails with invalid character in command name" {
    run knit_register "my cmd" knit_empty "Bad command."
    [ "$status" -eq 1 ]
}

@test "knit_register accepts a hyphen in the command name" {
    knit_register "db-show" knit_empty "A hyphenated command."
    knit_done
    # Identity is the underscore form.
    _knit_set_find _KNIT_COMMANDS "db_show"
}

@test "knit_register fails with a leading hyphen in the command name" {
    run knit_register "-bad" knit_empty "Bad command."
    [ "$status" -eq 1 ]
}

@test "knit_register fails if parent command not registered" {
    run knit_register "parent:child" knit_empty "Child command."
    [ "$status" -eq 1 ]
}

@test "knit_register fails if command already registered" {
    knit_register "dup_cmd" knit_empty "First registration."
    knit_done
    run knit_register "dup_cmd" knit_empty "Second registration."
    [ "$status" -eq 1 ]
}

@test "knit_register allows subcommand when parent is registered" {
    knit_register "par_cmd" knit_empty "Parent command."
    knit_done
    knit_register "par_cmd:sub" knit_empty "Subcommand."
    knit_done
    _knit_set_find _KNIT_COMMANDS "par_cmd__1__sub"
}

@test "knit_done fails if registered function is not defined" {
    knit_register "undef_cmd" undefined_fn "Test."
    run knit_done
    [ "$status" -eq 1 ]
}

# ---------- _knit_push_done_cb ----------

@test "_knit_push_done_cb fails outside of knit_register" {
    run _knit_push_done_cb echo "hello"
    [ "$status" -eq 1 ]
}

@test "_knit_push_done_cb callback is invoked at knit_done" {
    _KNIT_PDC_CALLED=false
    _pdc_mark_called() { _KNIT_PDC_CALLED=true; }
    pdc_fn_a() { :; }
    knit_register "pdc_a" pdc_fn_a "Test."
    _knit_push_done_cb _pdc_mark_called
    knit_done
    [ "${_KNIT_PDC_CALLED}" = "true" ]
}

@test "_knit_push_done_cb multiple callbacks run in reverse order" {
    declare -ga _KNIT_PDC_ORDER=()
    _pdc_order_append() { _KNIT_PDC_ORDER+=("$1"); }
    pdc_fn_b() { :; }
    knit_register "pdc_b" pdc_fn_b "Test."
    _knit_push_done_cb _pdc_order_append "first"
    _knit_push_done_cb _pdc_order_append "second"
    _knit_push_done_cb _pdc_order_append "third"
    knit_done
    [ "${_KNIT_PDC_ORDER[0]}" = "third" ]
    [ "${_KNIT_PDC_ORDER[1]}" = "second" ]
    [ "${_KNIT_PDC_ORDER[2]}" = "first" ]
}

@test "_knit_push_done_cb _KNIT_DONE_CBS is unset after knit_done" {
    pdc_fn_c() { :; }
    knit_register "pdc_c" pdc_fn_c "Test."
    _knit_push_done_cb echo "cb"
    knit_done
    [[ ! -v _KNIT_DONE_CBS ]]
}

@test "_knit_push_done_cb callbacks do not carry over to next registration" {
    _KNIT_PDC_COUNT=0
    _pdc_increment() { _KNIT_PDC_COUNT=$(( _KNIT_PDC_COUNT + 1 )); }
    pdc_fn_d() { :; }
    knit_register "pdc_d" pdc_fn_d "Test."
    _knit_push_done_cb _pdc_increment
    pdc_fn_e() { :; }
    knit_register "pdc_e" pdc_fn_e "Test."
    # implicit knit_done fired for pdc_d: count becomes 1
    knit_done
    # explicit knit_done for pdc_e: no callbacks pushed, count stays 1
    [ "${_KNIT_PDC_COUNT}" -eq 1 ]
}

# ---------- knit_hidden ----------

@test "knit_hidden marks a command as hidden" {
    knit_register "hid_cmd" knit_empty "A hidden command."
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
    knit_register "sct_cmd" knit_empty "Test."
    knit_with_subcommand_title "My Operations"
    knit_done
    [ "${_KNIT_CMD_sct_cmd_subcommand_title}" = "My Operations" ]
}

@test "knit_with_subcommand_title fails outside of knit_register" {
    run knit_with_subcommand_title "title"
    [ "$status" -eq 1 ]
}

# ---------- knit_with_flag ----------

@test "knit_with_flag registers a flag" {
    knit_register "flg_cmd" knit_empty "Test."
    knit_with_flag "verbose" "Enable verbose output."
    knit_done
    _knit_set_find "_KNIT_CMD_flg_cmd_flags" "verbose"
}

@test "knit_with_flag normalizes hyphens to underscores" {
    knit_register "flg_cmd2" knit_empty "Test."
    knit_with_flag "dry-run" "Dry run mode."
    knit_done
    _knit_set_find "_KNIT_CMD_flg_cmd2_flags" "dry_run"
}

@test "knit_with_flag fails outside of knit_register" {
    run knit_with_flag "verbose" "Enable verbose output."
    [ "$status" -eq 1 ]
}

@test "knit_with_flag rejects invalid flag name" {
    knit_register "flg_cmd3" knit_empty "Test."
    run knit_with_flag "invalid name" "Has a space."
    [ "$status" -eq 1 ]
}

# ---------- knit_with_extra ----------

@test "knit_with_extra stores the extra description" {
    knit_register "ext_cmd" knit_empty "Test."
    knit_with_extra "Extra arguments passed after --."
    knit_done
    [ "${_KNIT_CMD_ext_cmd_extra}" = "Extra arguments passed after --." ]
}

@test "knit_with_extra fails outside of knit_register" {
    run knit_with_extra "Extra args."
    [ "$status" -eq 1 ]
}

# ---------- knit_with_dispatch ----------

@test "knit_register initializes an empty dispatch marker" {
    knit_register "disp_init" knit_empty "Test."
    knit_done
    [ -v _KNIT_CMD_disp_init_dispatch ]
    [ -z "${_KNIT_CMD_disp_init_dispatch}" ]
}

@test "knit_with_dispatch stores the placeholder and description" {
    knit_register "disp_cmd" knit_empty "Test."
    knit_with_dispatch "job" "The job to submit."
    knit_done
    [ "${_KNIT_CMD_disp_cmd_dispatch}" = "job" ]
    [ "${_KNIT_CMD_disp_cmd_extra}" = "The job to submit." ]
}

@test "knit_with_dispatch defaults the extra description to the placeholder" {
    knit_register "disp_cmd2" knit_empty "Test."
    knit_with_dispatch "program"
    knit_done
    [ "${_KNIT_CMD_disp_cmd2_dispatch}" = "program" ]
    [ "${_KNIT_CMD_disp_cmd2_extra}" = "program" ]
}

@test "knit_with_dispatch fails outside of knit_register" {
    run knit_with_dispatch "job"
    [ "$status" -eq 1 ]
}

# ---------- _knit_param_check_declaration (edge cases) ----------

@test "knit_with_required fails outside of knit_register" {
    run knit_with_required "name:string" "A name."
    [ "$status" -eq 1 ]
}

@test "knit_with_required rejects invalid parameter name" {
    knit_register "inv_cmd" knit_empty "Test."
    run knit_with_required "invalid name:string" "A name."
    [ "$status" -eq 1 ]
}

@test "knit_with_required rejects duplicate parameter name" {
    knit_register "dup_param_cmd" knit_empty "Test."
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
    knit_register "rb_cmd" knit_empty "Test."
    _knit_run_before echo "before_output"
    knit_done
    [ "${#_KNIT_CMD_rb_cmd_before_cb[@]}" -eq 1 ]
}

@test "_knit_run_before fails outside of knit_register" {
    run _knit_run_before echo "before"
    [ "$status" -eq 1 ]
}

@test "_knit_run_after registers an after callback" {
    knit_register "ra_cmd" knit_empty "Test."
    _knit_run_after echo "after_output"
    knit_done
    [ "${#_KNIT_CMD_ra_cmd_after_cb[@]}" -eq 1 ]
}

@test "_knit_run_after fails outside of knit_register" {
    run _knit_run_after echo "after"
    [ "$status" -eq 1 ]
}

# ---------- _knit_execute_before_commands / _knit_execute_after_commands ----------

@test "_knit_execute_before_commands executes registered callbacks" {
    knit_register "eb_cmd" knit_empty "Test."
    _knit_run_before echo "before_output"
    knit_done
    local result
    result=$(_knit_execute_before_commands "eb_cmd")
    [ "$result" = "before_output" ]
}

@test "_knit_execute_before_commands does nothing when no callbacks registered" {
    knit_register "eb_cmd2" knit_empty "Test."
    knit_done
    local result
    result=$(_knit_execute_before_commands "eb_cmd2")
    [ -z "$result" ]
}

@test "_knit_execute_before_commands returns non-zero when a callback fails" {
    _eb_fail() { return 1; }
    knit_register "eb_cmd3" knit_empty "Test."
    _knit_run_before _eb_fail
    knit_done
    run _knit_execute_before_commands "eb_cmd3"
    [ "$status" -ne 0 ]
}

@test "_knit_execute_before_commands stops at the first failing callback" {
    _eb_fail2() { return 1; }
    _eb_second() { echo "second-ran"; }
    knit_register "eb_cmd4" knit_empty "Test."
    _knit_run_before _eb_fail2
    _knit_run_before _eb_second
    knit_done
    run _knit_execute_before_commands "eb_cmd4"
    [ "$status" -ne 0 ]
    [[ "$output" != *"second-ran"* ]]
}

@test "_knit_execute_before_commands returns zero when all callbacks succeed" {
    knit_register "eb_cmd5" knit_empty "Test."
    _knit_run_before echo "ok"
    knit_done
    run _knit_execute_before_commands "eb_cmd5"
    [ "$status" -eq 0 ]
}

@test "_knit_execute_after_commands executes registered callbacks" {
    knit_register "ea_cmd" knit_empty "Test."
    _knit_run_after echo "after_output"
    knit_done
    local result
    result=$(_knit_execute_after_commands "ea_cmd")
    [ "$result" = "after_output" ]
}

@test "_knit_execute_after_commands does nothing when no callbacks registered" {
    knit_register "ea_cmd2" knit_empty "Test."
    knit_done
    local result
    result=$(_knit_execute_after_commands "ea_cmd2")
    [ -z "$result" ]
}

# ---------- _knit_find_flag ----------

@test "_knit_find_flag returns 0 when flag is present" {
    _knit_find_flag "--verbose" "aaa" "--verbose" "bbb"
}

@test "_knit_find_flag returns 1 when flag is absent" {
    run _knit_find_flag "--verbose" "aaa" "bbb"
    [ "$status" -eq 1 ]
}

@test "_knit_find_flag stops searching after double dash" {
    run _knit_find_flag "--verbose" "aaa" "--" "--verbose"
    [ "$status" -eq 1 ]
}

@test "_knit_find_flag matches hyphen and underscore variants" {
    _knit_find_flag "--dry-run" "--dry_run"
    _knit_find_flag "--dry_run" "--dry-run"
}

