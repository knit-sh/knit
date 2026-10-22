#!/usr/bin/env bats
#
# M5 tests for sweep execution: the durable prepare path, the ephemeral search
# loop, the on-failure policy, --parallel forwarding, mode derivation, and the
# sweeps-row recording with its call edges to the children.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup
    _KNIT_JQ_EXE="jq"
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    _KNIT_RECORDING_SUPPRESSED=""
    # The jobs table the job-mode loop polls; the provenance edge table.
    sqlite3 "${_KNIT_DATABASE}" "CREATE TABLE IF NOT EXISTS jobs (id TEXT, state TEXT);"
    sqlite3 "${_KNIT_DATABASE}" "CREATE TABLE IF NOT EXISTS __provenance__ (source_id TEXT, source_name TEXT, target_id TEXT, target_name TEXT, edge_type TEXT, start_time REAL, end_time REAL, alias TEXT);"

    # A bare command that records a row (for the end-to-end provenance test).
    knit_register "render" _render "A plain command."
    knit_with_optional "width:integer" "256" "width"
    knit_with_table "renders"
    knit_with_output "doubled:integer" "0" "twice the width"
    _render() {
        local w
        w=$(knit_get_parameter width "$@")
        knit_output doubled "$(( w * 2 ))"
    }
    knit_done

    # A job and an app, used by the mode-derivation tests (with a stubbed loop).
    knit_register_job "montecarlo" _mc "A Monte Carlo job."
    knit_with_optional "samples:integer" "1000" "sample count" --domain '{1000,100000}'
    _mc() { :; }
    knit_done

    knit_register_app "stencil" _stencil "A stencil app."
    knit_with_optional "tile:integer" "64" "tile size"
    _stencil() { :; }
    knit_done

    LOG="$(mktemp)"
}

teardown() {
    rm -f "${LOG}"
    knit_test_db_teardown
}

# ---------- bare command, end to end (real launch) ----------

@test "a bare-command sweep records every child and a call edge from the sweep" {
    _knit_invoke_command "sweep" --group g -- render --width '{256,512,1024}'
    # One child row per product point.
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM renders;")" -eq 3 ]
    # The sweeps row records the campaign shape.
    local row
    row=$(sqlite3 "${_KNIT_DATABASE}" "SELECT target,dispatcher,count,dimensions FROM sweeps;")
    [ "${row}" = 'render|render|3|{"width":[256,512,1024]}' ]
    # Each child carries a call edge whose source is the sweeps row.
    local sid n
    sid=$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM sweeps;")
    n=$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM __provenance__ WHERE source_id='${sid}' AND edge_type='call';")
    [ "${n}" -eq 3 ]
}

# ---------- durable prepare path (sequential, stubbed launch) ----------

@test "a prepare sweep launches each point sequentially and runs no loop" {
    # Stub the launcher to log its line; stub the loop to prove it is not used.
    eval "knit_search_launch() { local -n _u=\$1; shift; printf '%s\n' \"\$*\" >> '${LOG}'; _u='x'; }"
    eval "knit_search_loop() { printf 'LOOP\n' >> '${LOG}'; }"
    _knit_invoke_command "sweep" --group mc -- prepare -- montecarlo --samples '{1000,100000}'
    # Two prepare lines, group spliced, no loop.
    [ "$(grep -c '^prepare ' "${LOG}")" -eq 2 ]
    [ "$(grep -c '^LOOP$' "${LOG}")" -eq 0 ]
    grep -qx 'prepare --group mc -- montecarlo --samples 1000' "${LOG}"
    grep -qx 'prepare --group mc -- montecarlo --samples 100000' "${LOG}"
}

# ---------- declared-domain resolution through the full command ----------

# Exercises _knit_sweep_resolve_target + _knit_sweep_resolve_domains via the real
# _knit_sweep body (not the helpers directly), which is where the target-command
# nameref must reach the body.
@test "--fill sweep resolves the job's declared domain end to end" {
    run _knit_invoke_command "sweep" --fill sweep --dry-run -- submit -- montecarlo
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "submit -- montecarlo --samples 1000" ]
    [ "${lines[1]}" = "submit -- montecarlo --samples 100000" ]
}

@test "@sweep resolves the job's declared domain end to end" {
    run _knit_invoke_command "sweep" --dry-run -- submit -- montecarlo --samples @sweep
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "submit -- montecarlo --samples 1000" ]
    [ "${lines[1]}" = "submit -- montecarlo --samples 100000" ]
}

# ---------- mode derivation (stubbed loop) ----------

@test "submit derives job mode; run and a bare command derive app mode" {
    eval "knit_search_loop() { while [[ \$# -gt 0 ]]; do [[ \$1 == --mode ]] && printf 'mode=%s\n' \"\$2\" >> '${LOG}'; shift; done; }"
    _knit_invoke_command "sweep" -- submit -- montecarlo --samples '{1,2}'
    _knit_invoke_command "sweep" -- run -- stencil --tile '{1,2}'
    _knit_invoke_command "sweep" -- render --width '{1,2}'
    [ "$(sed -n '1p' "${LOG}")" = "mode=job" ]
    [ "$(sed -n '2p' "${LOG}")" = "mode=app" ]
    [ "$(sed -n '3p' "${LOG}")" = "mode=app" ]
}

@test "--parallel is forwarded to the loop" {
    eval "knit_search_loop() { while [[ \$# -gt 0 ]]; do [[ \$1 == --parallel ]] && printf 'parallel=%s\n' \"\$2\" >> '${LOG}'; shift; done; }"
    _knit_invoke_command "sweep" --parallel 4 -- submit -- montecarlo --samples '{1,2}'
    [ "$(cat "${LOG}")" = "parallel=4" ]
}

# ---------- on-failure policy (real loop, stubbed launch) ----------

# Stub launch: record a terminal "failed" jobs row each call, logging the call.
_stub_launch_fail() {
    local -n _u=$1; shift
    printf 'launch\n' >> "${LOG}"
    local n
    n=$(grep -c '^launch$' "${LOG}")
    local uuid="job-${n}"
    sqlite3 "${_KNIT_DATABASE}" "INSERT INTO jobs (id,state) VALUES ('${uuid}','failed');"
    _u="${uuid}"
    return 0
}

@test "--on-failure stop aborts on the first failed child" {
    eval "knit_search_launch() { _stub_launch_fail \"\$@\"; }"
    run _knit_invoke_command "sweep" --on-failure stop --parallel 1 \
        -- submit -- montecarlo --samples '{1,2,3,4}'
    # The first child fails and aborts the campaign: only one launch.
    [ "$(grep -c '^launch$' "${LOG}")" -eq 1 ]
    [ "$status" -ne 0 ]
}

@test "--on-failure continue runs the whole product despite failures" {
    eval "knit_search_launch() { _stub_launch_fail \"\$@\"; }"
    _knit_invoke_command "sweep" --on-failure continue --parallel 1 \
        -- submit -- montecarlo --samples '{1,2,3,4}'
    # Every point launches even though each child fails.
    [ "$(grep -c '^launch$' "${LOG}")" -eq 4 ]
}
