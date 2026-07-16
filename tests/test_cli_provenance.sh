#!/usr/bin/env bats

# Provenance (M2): every invocation gets its own distinct row id, resolved when
# its frame is pushed so a nested child can read its parent's id while the
# parent's body still runs. Later milestones build the edge table and parent
# resolution on top of this stack; here we test the ids and their timing only.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_PARENT_ID KNIT_PARENT_COMMAND
    _KNIT_RECORDING_SUPPRESSED=""
    # Create the edge table up front so tests that record no edge (a "without"
    # command, KNIT_DISABLE_RECORDING) can still query __provenance__.
    _knit_prov_create_table
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

# ---------- call edges (M3, design §5.2/§5.6) ----------

@test "a root invocation records a call edge with empty parent columns" {
    knit_register _p_root_fn "rootcmd" "Root."
    knit_with_table "roots"
    _p_root_fn() { :; }
    knit_done

    _knit_invoke_command "rootcmd"

    local id
    id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM roots;")
    # A top-level command has no parent (in-process or exported): its edge records
    # empty parent columns and links to its own recorded row as the child.
    local edge
    edge=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT parent_id,parent_name,child_id,child_name,edge_type FROM __provenance__;")
    # Empty parent_id and parent_name render as two leading separators.
    [ "${edge}" = "||${id}|rootcmd|call" ]
}

@test "a nested child records a call edge to its parent" {
    knit_register _p_ce_child_fn "cechild" "Child."
    knit_with_table "cechildren"
    _p_ce_child_fn() { :; }
    knit_done

    knit_register _p_ce_parent_fn "ceparent" "Parent."
    knit_with_table "ceparents"
    _p_ce_parent_fn() { _knit_invoke_command "cechild"; }
    knit_done

    _knit_invoke_command "ceparent"

    local parent_id child_id
    parent_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM ceparents;")
    child_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM cechildren;")

    # The child's edge names the parent frame (id + demangled name); the parent
    # itself has a root edge (empty parent columns).
    local child_edge
    child_edge=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT parent_id,parent_name,child_name FROM __provenance__ WHERE child_id='${child_id}';")
    [ "${child_edge}" = "${parent_id}|ceparent|cechild" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT parent_id FROM __provenance__ WHERE child_id='${parent_id}';")" = "" ]
}

@test "a hidden intermediate command is transparent (A -> hidden M -> B collapses to A -> B)" {
    knit_register _p_b_fn "bcmd" "B."
    knit_with_table "bs"
    _p_b_fn() { :; }
    knit_done

    # A hidden command records nothing and is skipped when its callee resolves a
    # parent, so B's edge points straight at A.
    knit_register _p_mid_fn "_mid" "Middle."
    knit_hidden
    _p_mid_fn() { _knit_invoke_command "bcmd"; }
    knit_done

    knit_register _p_a_fn "acmd" "A."
    knit_with_table "a_rows"
    _p_a_fn() { _knit_invoke_command "_mid"; }
    knit_done

    _knit_invoke_command "acmd"

    local a_id b_id
    a_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM a_rows;")
    b_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM bs;")

    # B's parent is A (the hidden middle is transparent)...
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT parent_id,parent_name FROM __provenance__ WHERE child_id='${b_id}';")" \
        = "${a_id}|acmd" ]
    # ...and the hidden command appears nowhere in the graph.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM __provenance__ WHERE parent_name='_mid' OR child_name='_mid';")" \
        = "0" ]
}

@test "a call edge records REAL epoch timestamps with end_time >= start_time" {
    knit_register _p_ts_fn "tscmd" "Ts."
    knit_with_table "tss"
    _p_ts_fn() { :; }
    knit_done

    _knit_invoke_command "tscmd"

    local start_time end_time
    start_time=$(sqlite3 "${_KNIT_DATABASE}" "SELECT start_time FROM __provenance__;")
    end_time=$(sqlite3 "${_KNIT_DATABASE}" "SELECT end_time FROM __provenance__;")
    # Both are stored with REAL affinity (a fractional epoch second) and ordered.
    [[ "${start_time}" == *.* ]]
    [[ "${end_time}" == *.* ]]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT end_time >= start_time FROM __provenance__;")" = "1" ]
}

# ---------- exported parent context (design §5.2 rule 2) ----------

@test "the parent context falls back to the exported env with no in-process parent" {
    knit_register _p_env_fn "envcmd" "Env."
    knit_with_table "envs"
    _p_env_fn() { :; }
    knit_done

    # A freshly re-entered process (empty stack) reads the context its caller
    # exported across the boundary.
    KNIT_PARENT_ID="dad00000-0000-7000-8000-000000000000" \
        KNIT_PARENT_COMMAND="submit:mc" \
        _knit_invoke_command "envcmd"

    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT parent_id,parent_name FROM __provenance__;")" \
        = "dad00000-0000-7000-8000-000000000000|submit:mc" ]
}

@test "an in-process parent overrides the exported env" {
    knit_register _p_ov_child_fn "ovchild" "Child."
    knit_with_table "ovchildren"
    _p_ov_child_fn() { :; }
    knit_done

    knit_register _p_ov_parent_fn "ovparent" "Parent."
    knit_with_table "ovparents"
    _p_ov_parent_fn() { _knit_invoke_command "ovchild"; }
    knit_done

    # Even with an exported context present, the nearer in-process parent wins for
    # the child's edge (innermost wins).
    KNIT_PARENT_ID="dad00000-0000-7000-8000-000000000000" \
        KNIT_PARENT_COMMAND="submit:mc" \
        _knit_invoke_command "ovparent"

    local parent_id child_id
    parent_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM ovparents;")
    child_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM ovchildren;")
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT parent_id,parent_name FROM __provenance__ WHERE child_id='${child_id}';")" \
        = "${parent_id}|ovparent" ]
}

# ---------- recording policy: with/without marks (M4, design §5.5) ----------

@test "knit_without_provenance on a visible command records no edge but keeps its data row" {
    knit_register _p_wo_fn "wocmd" "Without."
    knit_with_table "wos"
    knit_without_provenance
    _p_wo_fn() { :; }
    knit_done

    _knit_invoke_command "wocmd"

    # The data row is still recorded (orthogonal to provenance)...
    [ -n "$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM wos;")" ]
    # ...but the command produces no provenance edge.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM __provenance__ WHERE child_name='wocmd';")" = "0" ]
}

@test "knit_with_provenance on a hidden command records an edge" {
    knit_register _p_wh_fn "_whcmd" "With, hidden."
    knit_hidden
    knit_with_provenance
    _p_wh_fn() { :; }
    knit_done

    _knit_invoke_command "_whcmd"

    # A hidden command is transparent by default, but the explicit "with" mark
    # forces it into the graph (as a root here — no participating parent).
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT parent_id,parent_name,child_name,edge_type FROM __provenance__;")" \
        = "||_whcmd|call" ]
}

@test "a without command is transparent: its child links to the grandparent" {
    knit_register _p_gc_fn "gchild" "Grandchild."
    knit_with_table "gchildren"
    _p_gc_fn() { :; }
    knit_done

    # A "without" middle command records no edge and is skipped when its callee
    # resolves a parent, so the grandchild's edge points at the top command.
    knit_register _p_mw_fn "midw" "Middle without."
    knit_without_provenance
    _p_mw_fn() { _knit_invoke_command "gchild"; }
    knit_done

    knit_register _p_gt_fn "gtop" "Top."
    knit_with_table "gtops"
    _p_gt_fn() { _knit_invoke_command "midw"; }
    knit_done

    _knit_invoke_command "gtop"

    local top_id gc_id
    top_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM gtops;")
    gc_id=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM gchildren;")

    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT parent_id,parent_name FROM __provenance__ WHERE child_id='${gc_id}';")" \
        = "${top_id}|gtop" ]
    # The "without" middle appears nowhere in the graph.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM __provenance__ WHERE parent_name='midw' OR child_name='midw';")" \
        = "0" ]
}

# ---------- recording policy: lexical inheritance (M4, design §5.5) ----------

@test "an unmarked nested command inherits a without mark from its lexical parent" {
    knit_register _p_par_fn "grp" "Group."
    knit_without_provenance
    _p_par_fn() { :; }
    knit_done

    knit_register _p_sub_fn "grp:leaf" "Leaf."
    knit_with_table "grpleaves"
    _p_sub_fn() { :; }
    knit_done

    _knit_invoke_command "grp:leaf"

    # grp:leaf is unmarked, but its lexical parent grp is "without", so it records
    # no edge (its data row is still written).
    [ -n "$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM grpleaves;")" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM __provenance__ WHERE child_name='grp:leaf';")" = "0" ]
}

@test "an unmarked nested command inherits a with mark from its lexical parent" {
    knit_register _p_wpar_fn "wgrp" "Group."
    knit_with_provenance
    _p_wpar_fn() { :; }
    knit_done

    knit_register _p_wsub_fn "wgrp:_leaf" "Hidden leaf."
    knit_hidden
    _p_wsub_fn() { :; }
    knit_done

    _knit_invoke_command "wgrp:_leaf"

    # wgrp:_leaf is hidden and would be transparent by default, but the inherited
    # "with" from wgrp overrides visibility, so it records an edge.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT child_name,edge_type FROM __provenance__;")" = "wgrp:_leaf|call" ]
}

@test "an explicit mark on a nested command overrides the inherited one" {
    knit_register _p_opar_fn "ogrp" "Group."
    knit_without_provenance
    _p_opar_fn() { :; }
    knit_done

    knit_register _p_osub_fn "ogrp:leaf" "Leaf with own mark."
    knit_with_provenance
    _p_osub_fn() { :; }
    knit_done

    _knit_invoke_command "ogrp:leaf"

    # ogrp is "without", but ogrp:leaf's own "with" wins.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT child_name,edge_type FROM __provenance__;")" = "ogrp:leaf|call" ]
}

@test "the nearest marked lexical ancestor wins over a farther one" {
    knit_register _p_np_fn "top" "Top."
    knit_with_provenance
    _p_np_fn() { :; }
    knit_done

    knit_register _p_nm_fn "top:mid" "Mid."
    knit_without_provenance
    _p_nm_fn() { :; }
    knit_done

    knit_register _p_nl_fn "top:mid:leaf" "Leaf."
    _p_nl_fn() { :; }
    knit_done

    _knit_invoke_command "top:mid:leaf"

    # top is "with" and top:mid is "without"; the unmarked leaf inherits from the
    # nearer top:mid, so it records no edge.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM __provenance__ WHERE child_name='top:mid:leaf';")" = "0" ]
}

# ---------- global kill switch (M4, design §7 D7) ----------

@test "KNIT_DISABLE_RECORDING suppresses both the data row and the edge" {
    knit_register _p_kill_fn "killcmd" "Kill."
    knit_with_table "kills"
    _p_kill_fn() { :; }
    knit_done

    KNIT_DISABLE_RECORDING=true _knit_invoke_command "killcmd"

    # Neither the data row nor the provenance edge is written.
    [ -z "$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM kills;")" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM __provenance__;")" = "0" ]
}

@test "KNIT_DISABLE_RECORDING also suppresses the eager _knit_record_row_now path" {
    knit_register _p_eager_fn "eagercmd" "Eager."
    knit_with_table "eagers"
    _p_eager_fn() { _knit_record_row_now "$@"; }
    knit_done

    KNIT_DISABLE_RECORDING=true _knit_invoke_command "eagercmd"

    [ -z "$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM eagers;")" ]
}
