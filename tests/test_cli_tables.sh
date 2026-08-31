#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- knit_with_table ----------

@test "knit_with_table defaults to colon-separated command name" {
    knit_register "foo" knit_empty "A parent command."
    knit_done
    knit_register "foo:bar" knit_empty "A subcommand."
    knit_with_table
    knit_done
    local result
    result=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='foo:bar';")
    [ "$result" -eq 1 ]
}

@test "knit_with_table accepts an explicit table name" {
    knit_register "mycmd" knit_empty "A command."
    knit_with_table "my_runs"
    knit_done
    local result
    result=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='my_runs';")
    [ "$result" -eq 1 ]
}

@test "knit_with_table for a simple command defaults to command name" {
    knit_register "solo" knit_empty "Do something."
    knit_with_table
    knit_done
    local result
    result=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='solo';")
    [ "$result" -eq 1 ]
}

@test "two commands with distinct table names both succeed" {
    knit_register "cmd1" knit_empty "First command."
    knit_with_table "table1"
    knit_done

    knit_register "cmd2" knit_empty "Second command."
    knit_with_table "table2"
    knit_done

    local r1 r2
    r1=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='table1';")
    r2=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='table2';")
    [ "$r1" -eq 1 ]
    [ "$r2" -eq 1 ]
}

@test "two commands sharing a table name causes a fatal error" {
    knit_register "cmd1" knit_empty "First command."
    knit_with_table "shared"
    knit_done

    knit_register "cmd2" knit_empty "Second command."
    run knit_with_table "shared"
    [ "$status" -ne 0 ]
}

@test "knit_with_table outside registration context causes a fatal error" {
    run knit_with_table "mytable"
    [ "$status" -ne 0 ]
}

@test "table created by knit_with_table has id as first column" {
    knit_register "mycmd" knit_empty "A command."
    knit_with_required "count:integer" "A count."
    knit_with_table
    knit_done
    local first_col
    first_col=$(sqlite3 "${_KNIT_DATABASE}" \
        "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | head -1)
    [ "$first_col" = "id" ]
}

@test "table contains columns for all params flags and outputs" {
    knit_register "mycmd" knit_empty "A command."
    knit_with_required "iters:integer" "Iterations."
    knit_with_optional "label:string" "none" "A label."
    knit_with_flag "verbose" "Verbose mode."
    knit_with_output "score:real" "0.0" "The score."
    knit_with_table
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" \
        "PRAGMA table_info('mycmd');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,iters,label,verbose,score," ]
}

@test "optional parameter default is used as migration default" {
    # Create the table first with only the id column (simulating old schema)
    knit_register "mycmd" knit_empty "A command."
    knit_with_table
    knit_done
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO mycmd (id) VALUES ('550e8400-e29b-41d4-a716-446655440000');"

    # Now add an optional parameter and re-run setup directly
    _knit_set_add "_KNIT_CMD_mycmd_optional" "label"
    eval "_KNIT_CMD_mycmd_2_label_type=string"
    eval "_KNIT_CMD_mycmd_2_label_default=mydefault"
    _knit_db_setup_table "mycmd" "mycmd"

    local val
    val=$(sqlite3 "${_KNIT_DATABASE}" "SELECT label FROM mycmd;")
    [ "$val" = "mydefault" ]
}

# ---------- knit_parameter_set / knit_with_parameter_set ----------

@test "knit_parameter_set defines a parameter set" {
    knit_parameter_set "my_params"
    knit_done
    [[ -v "_KNIT_PARAMETER_SETS[my_params]" ]]
}

@test "knit_parameter_set with required/optional/flag stores params in pset namespace" {
    knit_parameter_set "job_params"
    knit_with_required "nodes:integer" "Node count."
    knit_with_optional "label:string" "none" "A label."
    knit_with_flag "verbose" "Verbose mode."
    knit_done
    _knit_set_find "_KNIT_PSET_job_params_required" "nodes"
    _knit_set_find "_KNIT_PSET_job_params_optional" "label"
    _knit_set_find "_KNIT_PSET_job_params_flags" "verbose"
}

@test "knit_with_parameter_set imports params into a command" {
    knit_parameter_set "shared"
    knit_with_required "nodes:integer" "Node count."
    knit_with_optional "label:string" "none" "A label."
    knit_with_flag "verbose" "Verbose mode."
    knit_done

    knit_register "pset_cmd1" knit_empty "A command."
    knit_with_parameter_set "shared"
    knit_done

    _knit_set_find "_KNIT_CMD_pset_cmd1_required" "nodes"
    _knit_set_find "_KNIT_CMD_pset_cmd1_optional" "label"
    _knit_set_find "_KNIT_CMD_pset_cmd1_flags" "verbose"
}

@test "knit_with_parameter_set copies parameter metadata" {
    knit_parameter_set "meta_set"
    knit_with_required "size:integer" "Size of the job."
    knit_with_optional "tag:string" "default_tag" "A tag."
    knit_done

    knit_register "meta_cmd" knit_empty "A command."
    knit_with_parameter_set "meta_set"
    knit_done

    [ "${_KNIT_CMD_meta_cmd_2_size_type}" = "integer" ]
    [ "${_KNIT_CMD_meta_cmd_2_size_description}" = "Size of the job." ]
    [ "${_KNIT_CMD_meta_cmd_2_tag_type}" = "string" ]
    [ "${_KNIT_CMD_meta_cmd_2_tag_default}" = "default_tag" ]
    [ "${_KNIT_CMD_meta_cmd_2_tag_description}" = "A tag." ]
}

@test "knit_with_parameter_set lets the command be invoked with pset params" {
    knit_parameter_set "run_params"
    knit_with_required "nodes:integer" "Node count."
    knit_with_optional "label:string" "default" "A label."
    knit_done

    local captured_nodes captured_label
    run_pset_cmd() {
        captured_nodes=$(knit_get_parameter "nodes" "$@")
        captured_label=$(knit_get_parameter "label" "$@")
    }
    knit_register "run_pset_cmd" run_pset_cmd "A command."
    knit_with_parameter_set "run_params"
    knit_done

    _knit_invoke_command "run_pset_cmd" "--nodes" "4"
    [ "${captured_nodes}" = "4" ]
    [ "${captured_label}" = "default" ]
}

@test "two commands can share the same parameter set independently" {
    knit_parameter_set "shared2"
    knit_with_required "nodes:integer" "Node count."
    knit_done

    local captured_a captured_b
    cmd_a() { captured_a=$(knit_get_parameter "nodes" "$@"); }
    cmd_b() { captured_b=$(knit_get_parameter "nodes" "$@"); }
    knit_register "cmd_a" cmd_a "Command A."
    knit_with_parameter_set "shared2"
    knit_done
    knit_register "cmd_b" cmd_b "Command B."
    knit_with_parameter_set "shared2"
    knit_done

    _knit_invoke_command "cmd_a" "--nodes" "2"
    _knit_invoke_command "cmd_b" "--nodes" "8"
    [ "${captured_a}" = "2" ]
    [ "${captured_b}" = "8" ]
}

@test "multiple parameter sets can be applied to one command" {
    knit_parameter_set "set_a"
    knit_with_required "nodes:integer" "Node count."
    knit_done
    knit_parameter_set "set_b"
    knit_with_required "walltime:integer" "Walltime in seconds."
    knit_done

    knit_register "multi_pset_cmd" knit_empty "A command."
    knit_with_parameter_set "set_a"
    knit_with_parameter_set "set_b"
    knit_done

    _knit_set_find "_KNIT_CMD_multi_pset_cmd_required" "nodes"
    _knit_set_find "_KNIT_CMD_multi_pset_cmd_required" "walltime"
}

@test "command-level params and pset params coexist" {
    knit_parameter_set "base_set"
    knit_with_required "nodes:integer" "Node count."
    knit_done

    knit_register "mixed_cmd" knit_empty "A command."
    knit_with_required "app:string" "Application name."
    knit_with_parameter_set "base_set"
    knit_done

    _knit_set_find "_KNIT_CMD_mixed_cmd_required" "app"
    _knit_set_find "_KNIT_CMD_mixed_cmd_required" "nodes"
}

@test "knit_with_parameter_set fails for undefined set" {
    knit_register "nosuchset_cmd" knit_empty "A command."
    run knit_with_parameter_set "nonexistent"
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_parameter_set fails when pset param conflicts with command param" {
    knit_parameter_set "conflict_set"
    knit_with_required "nodes:integer" "Node count."
    knit_done

    knit_register "conflict_cmd" knit_empty "A command."
    knit_with_required "nodes:integer" "Already declared."
    run knit_with_parameter_set "conflict_set"
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_parameter_set fails when two psets have the same param" {
    knit_parameter_set "overlap_a"
    knit_with_required "nodes:integer" "Node count."
    knit_done
    knit_parameter_set "overlap_b"
    knit_with_required "nodes:integer" "Same name."
    knit_done

    knit_register "overlap_cmd" knit_empty "A command."
    knit_with_parameter_set "overlap_a"
    run knit_with_parameter_set "overlap_b"
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_parameter_set fails for invalid name" {
    run knit_parameter_set "invalid name"
    [ "$status" -eq 1 ]
}

@test "knit_parameter_set fails for duplicate set name" {
    knit_parameter_set "dup_set"
    knit_done
    run knit_parameter_set "dup_set"
    [ "$status" -eq 1 ]
}

@test "knit_parameter_set fails inside another parameter set definition" {
    knit_parameter_set "outer_set"
    run knit_parameter_set "inner_set"
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_with_parameter_set fails outside of knit_register" {
    knit_parameter_set "standalone_set"
    knit_done
    run knit_with_parameter_set "standalone_set"
    [ "$status" -eq 1 ]
}

@test "knit_with_required fails with duplicate within a parameter set" {
    knit_parameter_set "dup_param_set"
    knit_with_required "nodes:integer" "First declaration."
    run knit_with_required "nodes:integer" "Duplicate."
    [ "$status" -eq 1 ]
    knit_done
}

@test "knit_parameter_set auto-calls knit_done if knit_register is open" {
    knit_register "auto_done_cmd" knit_empty "A command."
    knit_parameter_set "auto_done_set"
    knit_done
    # Both registrations should have completed without error.
    _knit_set_find _KNIT_COMMANDS "auto_done_cmd"
    [[ -v "_KNIT_PARAMETER_SETS[auto_done_set]" ]]
}

@test "pset params appear in --help output for the command" {
    knit_parameter_set "help_set"
    knit_with_required "nodes:integer" "Number of nodes."
    knit_done

    knit_register "help_pset_cmd" knit_empty "A command with pset params."
    knit_with_parameter_set "help_set"
    knit_done

    run _knit_invoke_command "help_pset_cmd" "--help"
    [[ "$output" == *"nodes"* ]]
}

