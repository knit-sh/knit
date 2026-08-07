#!/usr/bin/env bats

# knit_as: name a call so distinct invocations of the same command are
# distinguishable in a query. The alias lands on the delegated invocation's "call"
# edge (NULL for a plain call), never on the nested edges its body records, and is
# validated at the call site (non-empty, not a table name, not reused).

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    _KNIT_RECORDING_SUPPRESSED=""
    _knit_prov_create_table
}

teardown() {
    knit_test_db_teardown
}

# ---------- alias recording ----------

@test "knit_as records the alias on the delegated call edge" {
    knit_register "ascmd" _as_c_fn "As cmd."
    knit_with_table "as_rows"
    _as_c_fn() { :; }
    knit_done

    knit_as fast ascmd

    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT alias FROM __provenance__ WHERE target_name='ascmd';")" = "fast" ]
}

@test "a plain invocation leaves the call edge alias NULL" {
    knit_register "plaincmd" _as_plain_fn "Plain."
    knit_with_table "plain_rows"
    _as_plain_fn() { :; }
    knit_done

    _knit_invoke_command "plaincmd"

    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM __provenance__ WHERE target_name='plaincmd' AND alias IS NULL;")" \
        = "1" ]
}

@test "a table-less command records its alias on the standalone edge" {
    knit_register "notablecmd" _as_nt_fn "No table."
    _as_nt_fn() { :; }
    knit_done

    knit_as quick notablecmd

    # No data row, but the standalone call edge still carries the alias.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT alias FROM __provenance__ WHERE target_name='notablecmd';")" = "quick" ]
}

@test "the alias lands only on the named call, not the nested edges its body records" {
    knit_register "aschild" _as_child_fn "Child."
    knit_with_table "aschildren"
    _as_child_fn() { :; }
    knit_done

    knit_register "asparent" _as_parent_fn "Parent."
    knit_with_table "asparents"
    _as_parent_fn() { _knit_invoke_command "aschild"; }
    knit_done

    knit_as fast asparent

    # The directly named parent call carries the alias...
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT alias FROM __provenance__ WHERE target_name='asparent';")" = "fast" ]
    # ...and the nested child call it makes does not (its alias is NULL).
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM __provenance__ WHERE target_name='aschild' AND alias IS NULL;")" \
        = "1" ]
}

@test "the same alias may be reused under different parent invocations" {
    knit_register "rchild" _as_r_child_fn "Child."
    knit_with_table "rchildren"
    _as_r_child_fn() { :; }
    knit_done

    # Two distinct parents each alias a child call "fast": different invocations,
    # so no collision.
    knit_register "rp1" _as_r_p1_fn "Parent 1."
    knit_with_table "rp1s"
    _as_r_p1_fn() { knit_as fast rchild; }
    knit_done

    knit_register "rp2" _as_r_p2_fn "Parent 2."
    knit_with_table "rp2s"
    _as_r_p2_fn() { knit_as fast rchild; }
    knit_done

    _knit_invoke_command "rp1"
    _knit_invoke_command "rp2"

    # Both aliased child edges are recorded.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM __provenance__ WHERE target_name='rchild' AND alias='fast';")" \
        = "2" ]
}

# ---------- validation ----------

@test "knit_as rejects an empty alias" {
    knit_register "ecmd" _as_e_fn "E."
    _as_e_fn() { :; }
    knit_done

    run knit_as "" ecmd
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-empty alias"* ]]
}

@test "knit_as rejects a missing command" {
    run knit_as fast
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a command"* ]]
}

@test "knit_as rejects an alias that collides with a registered table name" {
    knit_register "colcmd" _as_col_fn "Collide."
    knit_with_table "collide_t"
    _as_col_fn() { :; }
    knit_done

    run knit_as collide_t colcmd
    [ "$status" -ne 0 ]
    [[ "$output" == *"collides with a registered table name"* ]]
}

@test "knit_as rejects an alias reused within the same invocation" {
    knit_register "rucmd" _as_ru_fn "Reuse."
    knit_with_table "ru_rows"
    _as_ru_fn() { :; }
    knit_done

    knit_as fast rucmd
    run knit_as fast rucmd
    [ "$status" -ne 0 ]
    [[ "$output" == *"already used in this invocation"* ]]
}
