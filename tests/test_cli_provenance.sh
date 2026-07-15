#!/usr/bin/env bats

# Provenance (M2): every invocation gets its own distinct row id, resolved when
# its frame is pushed so a nested child can read its parent's id while the
# parent's body still runs. Later milestones build the edge table and parent
# resolution on top of this stack; here we test the ids and their timing only.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    unset KNIT_JOB_PREFIX KNIT_RUN_ID
    _KNIT_RECORDING_SUPPRESSED=""
}

teardown() {
    knit_test_db_teardown
}

# ---------- push-time row-id resolution ----------

@test "a frame's resolved id is visible on the stack while its body runs" {
    knit_register _p_seen_fn "seencmd" "Seen."
    knit_with_table "seens"
    # The body reads the id resolved for its own frame (the top of the stack).
    _p_seen_fn() { __seen_id="${_KNIT_EXECUTING_ROW_ID[-1]}"; }
    knit_done

    _knit_invoke_command "seencmd"

    # The id the body observed on the stack is exactly the id recorded, so a
    # child that reads it as its parent sees the id the parent will record.
    local recorded
    recorded=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM seens;")
    [ -n "${__seen_id}" ]
    [ "${__seen_id}" = "${recorded}" ]
}

# ---------- distinct ids ----------

@test "a nested child records an id distinct from its parent" {
    knit_register _p_child_fn "pchild" "Child."
    knit_with_table "pchildren"
    _p_child_fn() { :; }
    knit_done

    knit_register _p_parent_fn "pparent" "Parent."
    knit_with_table "pparents"
    _p_parent_fn() { _knit_invoke_command "pchild"; }
    knit_done

    _knit_invoke_command "pparent"

    local parent_id child_id
    parent_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM pparents;")
    child_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM pchildren;")
    [ -n "${parent_id}" ]
    [ -n "${child_id}" ]
    [ "${parent_id}" != "${child_id}" ]
}

# ---------- row-id timing (design §5.2) ----------

@test "a nested child sees its parent's explicit _knit_set_row_id as the parent frame id" {
    knit_register _p_probe_fn "probecmd" "Probe."
    # The parent frame's resolved id is the entry just below this frame's own.
    _p_probe_fn() { __probed_parent_id="${_KNIT_EXECUTING_ROW_ID[-2]}"; }
    knit_done

    knit_register _p_top_fn "topcmd" "Top."
    knit_with_table "tops"
    _p_top_fn() {
        _knit_set_row_id "cafe0000-0000-7000-8000-000000000000"
        _knit_invoke_command "probecmd"
    }
    knit_done

    _knit_invoke_command "topcmd"

    # The child observed exactly the id the parent set, and the parent recorded
    # that same id: the explicit override and the recorded id never diverge.
    [ "${__probed_parent_id}" = "cafe0000-0000-7000-8000-000000000000" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM tops;")" \
        = "cafe0000-0000-7000-8000-000000000000" ]
}
