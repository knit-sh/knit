#!/usr/bin/env bats
#
# Tests for knit_command_outputs and knit_command_table public accessors.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- knit_command_outputs ----------

@test "knit_command_outputs returns declared outputs in declaration order" {
    knit_register "alpha" _alpha_fn "Alpha."
    knit_with_table "alphas"
    knit_with_output "score:real" "0.0" "The score."
    knit_with_output "label:string" "" "The label."
    _alpha_fn() { :; }
    knit_done

    local -a outs
    knit_command_outputs outs "alpha"
    [ "${#outs[@]}" -eq 2 ]
    [ "${outs[0]}" = "score" ]
    [ "${outs[1]}" = "label" ]
}

@test "knit_command_outputs returns an empty array for a command with no outputs" {
    knit_register "beta" _beta_fn "Beta."
    _beta_fn() { :; }
    knit_done

    local -a outs
    knit_command_outputs outs "beta"
    [ "${#outs[@]}" -eq 0 ]
}

@test "knit_command_outputs works for a mangled nested command name" {
    knit_register "gamma" _gamma_fn "Parent."
    _gamma_fn() { :; }
    knit_done

    knit_register "gamma:delta" _gd_fn "Nested."
    knit_with_output "value:integer" "0" "A value."
    _gd_fn() { :; }
    knit_done

    local -a outs
    knit_command_outputs outs "gamma__1__delta"
    [ "${#outs[@]}" -eq 1 ]
    [ "${outs[0]}" = "value" ]
}

# ---------- knit_command_table ----------

@test "knit_command_table returns the declared table name" {
    knit_register "epsilon" _eps_fn "Epsilon."
    knit_with_table "epsilon_runs"
    _eps_fn() { :; }
    knit_done

    local tbl
    knit_command_table tbl "epsilon"
    [ "${tbl}" = "epsilon_runs" ]
}

@test "knit_command_table returns an empty string when no table is declared" {
    knit_register "zeta" _zeta_fn "Zeta."
    _zeta_fn() { :; }
    knit_done

    local tbl
    knit_command_table tbl "zeta"
    [ "${tbl}" = "" ]
}

@test "knit_command_table returns the default table name when knit_with_table has no argument" {
    knit_register "eta" _eta_fn "Eta."
    knit_with_table
    _eta_fn() { :; }
    knit_done

    local tbl
    knit_command_table tbl "eta"
    [ "${tbl}" = "eta" ]
}
