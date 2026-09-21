#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    # Used by the --json-summary path and the --when guard; harmless when unset
    # (only the JSON tests exercise it, and they skip when jq is unavailable).
    _KNIT_JQ_EXE="jq"

    # Stub the release primitive with a programmable queue so the loop logic can
    # be exercised without a live scheduler. Each entry is "uuid:rc"; a drained
    # queue yields no UUID and a non-zero status. The real function is called via
    # command substitution and, for the pool, from concurrent background workers,
    # so the queue lives in a file and is popped atomically under a flock. The
    # stub also tracks the peak number of concurrently active claims (in
    # _DRAIN_MAX), and sleeps for _DRAIN_SLEEP seconds while "running" a job so a
    # concurrency test can force workers to overlap.
    _DRAIN_FILE="$(mktemp)"
    _DRAIN_LOCK="$(mktemp)"
    _DRAIN_ACTIVE="$(mktemp)"
    _DRAIN_MAX="$(mktemp)"
    _DRAIN_SLEEP=""
    _drain_program() {
        if (( $# == 0 )); then
            : > "${_DRAIN_FILE}"
        else
            printf '%s\n' "$@" > "${_DRAIN_FILE}"
        fi
        printf '0' > "${_DRAIN_ACTIVE}"
        printf '0' > "${_DRAIN_MAX}"
    }
    _knit_drain_release_next() {
        local entry="" cur mx
        exec 9>"${_DRAIN_LOCK}"; flock 9
        IFS= read -r entry < "${_DRAIN_FILE}" || entry=""
        if [[ -n "${entry}" ]]; then
            sed -i '1d' "${_DRAIN_FILE}"
            cur=$(( $(cat "${_DRAIN_ACTIVE}") + 1 ))
            printf '%s' "${cur}" > "${_DRAIN_ACTIVE}"
            mx=$(cat "${_DRAIN_MAX}")
            (( cur > mx )) && printf '%s' "${cur}" > "${_DRAIN_MAX}"
        fi
        flock -u 9; exec 9>&-
        [[ -z "${entry}" ]] && return 1
        [[ -n "${_DRAIN_SLEEP}" ]] && sleep "${_DRAIN_SLEEP}"
        exec 9>"${_DRAIN_LOCK}"; flock 9
        printf '%s' "$(( $(cat "${_DRAIN_ACTIVE}") - 1 ))" > "${_DRAIN_ACTIVE}"
        flock -u 9; exec 9>&-
        printf '%s\n' "${entry%%:*}"
        return "${entry##*:}"
    }
    _drain_program
}

teardown() {
    rm -f "${_DRAIN_FILE}" "${_DRAIN_LOCK}" "${_DRAIN_ACTIVE}" "${_DRAIN_MAX}"
    knit_test_db_teardown
}

# ---------- serial mode (--max-inflight 1) ----------

@test "serial drains all jobs and reports success" {
    _drain_program u1:0 u2:0
    run _knit_drain_serial false "" false
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 2 job(s): 2 completed, 0 failed."* ]]
}

@test "serial reports a failure and exits non-zero" {
    _drain_program u1:0 u2:7 u3:0
    run _knit_drain_serial false "" false
    [ "$status" -ne 0 ]
    [[ "$output" == *"Released 3 job(s): 2 completed, 1 failed."* ]]
}

@test "serial --count caps the number of releases" {
    _drain_program u1:0 u2:0 u3:0 u4:0
    run _knit_drain_serial false 2 false
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 2 job(s): 2 completed, 0 failed."* ]]
}

@test "serial --stop-on-failure halts after the first failure" {
    _drain_program u1:0 u2:7 u3:0
    run _knit_drain_serial true "" false
    [ "$status" -ne 0 ]
    # Only two jobs were released (u3 is never claimed).
    [[ "$output" == *"Released 2 job(s): 1 completed, 1 failed."* ]]
}

@test "serial reports an empty queue" {
    _drain_program
    run _knit_drain_serial false "" false
    [ "$status" -eq 0 ]
    [[ "$output" == *"No prepared jobs to release."* ]]
}

# ---------- no-limit mode (--max-inflight 0) ----------

@test "no-limit releases every job without observing outcomes" {
    _drain_program u1:0 u2:7 u3:0
    run _knit_drain_nolimit "" false
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 3 job(s)."* ]]
    [[ "$output" != *"completed"* ]]
}

@test "no-limit --count caps the number of releases" {
    _drain_program u1:0 u2:0 u3:0
    run _knit_drain_nolimit 2 false
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 2 job(s)."* ]]
}

@test "no-limit reports an empty queue" {
    _drain_program
    run _knit_drain_nolimit "" false
    [ "$status" -eq 0 ]
    [[ "$output" == *"No prepared jobs to release."* ]]
}

# ---------- option validation ----------

@test "negative --max-inflight is fatal" {
    run _knit_submit_drain --max-inflight -1
    [ "$status" -ne 0 ]
    [[ "$output" == *"max-inflight"* ]]
}

@test "--count below 1 is fatal" {
    run _knit_submit_drain --max-inflight 1 --count 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"count"* ]]
}

@test "--stop-on-failure with --max-inflight 0 is rejected by the when guard" {
    knit_test_require_jq
    _KNIT_JQ_EXE="jq"
    run knit submit drain --max-inflight 0 --stop-on-failure
    [ "$status" -ne 0 ]
    [[ "$output" == *"stop_on_failure"* ]]
}

# ---------- throttled pool (--max-inflight N > 1) ----------

@test "pool drains all jobs and reports the breakdown" {
    _drain_program a:0 b:0 c:0 d:0 e:0 f:0
    run _knit_drain_pool 3 false "" false
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 6 job(s): 6 completed, 0 failed."* ]]
}

@test "pool keeps concurrency within --max-inflight" {
    _drain_program a:0 b:0 c:0 d:0 e:0 f:0 g:0 h:0 i:0
    _DRAIN_SLEEP="0.15"
    run _knit_drain_pool 3 false "" false
    [ "$status" -eq 0 ]
    local mx
    mx=$(cat "${_DRAIN_MAX}")
    [ "$mx" -le 3 ]
    [ "$mx" -ge 2 ]
}

@test "pool --count caps total releases under concurrency" {
    _drain_program a:0 b:0 c:0 d:0 e:0 f:0 g:0 h:0 i:0 j:0
    run _knit_drain_pool 3 false 4 false
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 4 job(s): 4 completed, 0 failed."* ]]
    # Six entries are left unclaimed.
    [ "$(wc -l < "${_DRAIN_FILE}")" -eq 6 ]
}

@test "pool reports a failure and exits non-zero" {
    _drain_program a:0 b:7 c:0
    run _knit_drain_pool 3 false "" false
    [ "$status" -ne 0 ]
    [[ "$output" == *"Released 3 job(s): 2 completed, 1 failed."* ]]
}

@test "pool --stop-on-failure stops launching new jobs after a failure" {
    _drain_program x:7 a:0 b:0 c:0 d:0 e:0 f:0 g:0
    run _knit_drain_pool 2 true "" false
    [ "$status" -ne 0 ]
    # Stop kicked in, so the queue was not fully drained.
    [ "$(wc -l < "${_DRAIN_FILE}")" -gt 0 ]
}

# ---------- --json-summary ----------

# Extract the single JSON summary line (the only line starting with "{") from a
# run's combined output.
_drain_json() { printf '%s\n' "$1" | grep '^{'; }

@test "serial --json-summary emits a valid, well-typed object" {
    knit_test_require_jq
    _drain_program a:0 b:7 c:0
    run _knit_drain_serial false "" true
    [ "$status" -ne 0 ]
    local json
    json=$(_drain_json "$output")
    [ -n "$json" ]
    jq -e '.released==3 and .completed==2 and .failed==1 and .drained==true and .stopped==false and .dry_run==false' <<<"$json"
}

@test "serial --json-summary reports stopped=true when a failure halts it" {
    knit_test_require_jq
    _drain_program a:0 b:7 c:0
    run _knit_drain_serial true "" true
    [ "$status" -ne 0 ]
    jq -e '.released==2 and .failed==1 and .stopped==true and .drained==false' <<<"$(_drain_json "$output")"
}

@test "serial --json-summary is emitted even when nothing is released" {
    knit_test_require_jq
    _drain_program
    run _knit_drain_serial false "" true
    [ "$status" -eq 0 ]
    jq -e '.released==0 and .completed==0 and .failed==0 and .drained==true' <<<"$(_drain_json "$output")"
}

@test "no-limit --json-summary reports null completed and failed" {
    knit_test_require_jq
    _drain_program a:0 b:7 c:0
    run _knit_drain_nolimit "" true
    [ "$status" -eq 0 ]
    jq -e '.released==3 and .completed==null and .failed==null and .drained==true and .stopped==false' <<<"$(_drain_json "$output")"
}

@test "pool --json-summary emits the counts" {
    knit_test_require_jq
    _drain_program a:0 b:0 c:0 d:7
    run _knit_drain_pool 2 false "" true
    [ "$status" -ne 0 ]
    jq -e '.released==4 and .completed==3 and .failed==1 and .dry_run==false' <<<"$(_drain_json "$output")"
}

@test "submit drain --json-summary passes the flag through" {
    knit_test_require_jq
    _drain_program a:0 b:0
    run _knit_submit_drain --json-summary true
    [ "$status" -eq 0 ]
    jq -e '.released==2 and .completed==2' <<<"$(_drain_json "$output")"
}

# ---------- --dry-run ----------

# Seed a real jobs table with prepared and non-prepared rows (id order matters:
# the dry run lists prepared jobs by ascending id).
_seed_jobs() {
    sqlite3 "${_KNIT_DATABASE}" \
        "CREATE TABLE jobs (id TEXT, job TEXT, \"group\" TEXT, state TEXT);
         INSERT INTO jobs VALUES
           ('j01','alpha','g1','prepared'),
           ('j02','beta','','prepared'),
           ('j03','gamma','g1','submitted'),
           ('j04','alpha','g2','prepared');"
}

_prepared_count() {
    sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM jobs WHERE state='prepared';"
}

@test "dry-run lists prepared jobs in id order and skips non-prepared" {
    _seed_jobs
    run _knit_drain_dry_run "" false "" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"j01  alpha  [g1]"* ]]
    [[ "$output" == *"j02  beta"* ]]
    [[ "$output" == *"j04  alpha  [g2]"* ]]
    # j03 is submitted, not prepared.
    [[ "$output" != *"j03"* ]]
    [[ "$output" == *"3 prepared job(s) would be released"* ]]
}

@test "dry-run claims nothing (queue unchanged)" {
    _seed_jobs
    [ "$(_prepared_count)" -eq 3 ]
    run _knit_drain_dry_run "" false "" ""
    [ "$status" -eq 0 ]
    [ "$(_prepared_count)" -eq 3 ]
}

@test "dry-run honors --count" {
    _seed_jobs
    run _knit_drain_dry_run 2 false "" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"j01"* ]]
    [[ "$output" == *"j02"* ]]
    [[ "$output" != *"j04"* ]]
}

@test "dry-run filters by type" {
    _seed_jobs
    run _knit_drain_dry_run "" false alpha ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"j01"* ]]
    [[ "$output" == *"j04"* ]]
    [[ "$output" != *"j02"* ]]
}

@test "dry-run filters by group" {
    _seed_jobs
    run _knit_drain_dry_run "" false "" g1
    [ "$status" -eq 0 ]
    [[ "$output" == *"j01"* ]]
    # j03 is g1 but submitted; j02/j04 are other/blank groups.
    [[ "$output" != *"j02"* ]]
    [[ "$output" != *"j04"* ]]
}

@test "dry-run --json-summary emits the peeked list" {
    knit_test_require_jq
    _seed_jobs
    run _knit_drain_dry_run "" true "" ""
    [ "$status" -eq 0 ]
    jq -e '.dry_run==true and .count==3 and (.jobs|length)==3 and .jobs[0].id=="j01"' <<<"$output"
}

@test "dry-run --json-summary on an empty match yields an empty list" {
    knit_test_require_jq
    _seed_jobs
    run _knit_drain_dry_run "" true nosuchjob ""
    [ "$status" -eq 0 ]
    jq -e '.dry_run==true and .count==0 and (.jobs|length)==0' <<<"$output"
}

@test "submit drain --dry-run lists without releasing" {
    _seed_jobs
    run _knit_submit_drain --dry-run true
    [ "$status" -eq 0 ]
    [[ "$output" == *"j01"* ]]
    [ "$(_prepared_count)" -eq 3 ]
}

# ---------- detached: backend resolution ----------

@test "detach backend auto prefers tmux" {
    _knit_command_path() { case "$1" in tmux|screen|nohup) echo "/usr/bin/$1";; esac; }
    local b
    _knit_drain_detach_backend b auto
    [ "$b" = tmux ]
}

@test "detach backend auto falls back to screen when tmux is absent" {
    _knit_command_path() { case "$1" in screen|nohup) echo "/usr/bin/$1";; esac; }
    local b
    _knit_drain_detach_backend b auto
    [ "$b" = screen ]
}

@test "detach backend auto falls back to nohup when tmux and screen are absent" {
    _knit_command_path() { case "$1" in nohup) echo "/usr/bin/$1";; esac; }
    local b
    _knit_drain_detach_backend b auto
    [ "$b" = nohup ]
}

@test "detach backend named-but-absent is fatal" {
    _knit_command_path() { return 0; }  # everything absent (no output)
    run _knit_drain_detach_backend b tmux
    [ "$status" -ne 0 ]
    [[ "$output" == *"not installed"* ]]
}

@test "detach backend named-and-present is accepted" {
    _knit_command_path() { echo "/usr/bin/$1"; }
    local b
    _knit_drain_detach_backend b screen
    [ "$b" = screen ]
}

@test "detach backend unknown value is fatal" {
    run _knit_drain_detach_backend b bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown --detach-backend"* ]]
}

# ---------- detached: child command reconstruction ----------

@test "child argv includes all provided options" {
    _KNIT_SCRIPT_PATH="/x/exp.sh"
    local -a c
    _knit_drain_child_argv c alpha g1 4 10 true true
    [ "${c[0]}" = "/x/exp.sh" ]
    local j="${c[*]}"
    [[ "$j" == *"submit drain"* ]]
    [[ "$j" == *"--type alpha"* ]]
    [[ "$j" == *"--group g1"* ]]
    [[ "$j" == *"--max-inflight 4"* ]]
    [[ "$j" == *"--count 10"* ]]
    [[ "$j" == *"--stop-on-failure"* ]]
    [[ "$j" == *"--json-summary"* ]]
}

@test "child argv omits absent filters and flags" {
    _KNIT_SCRIPT_PATH="/x/exp.sh"
    local -a c
    _knit_drain_child_argv c "" "" 1 "" false false
    local j="${c[*]}"
    [[ "$j" != *"--type"* ]]
    [[ "$j" != *"--group"* ]]
    [[ "$j" != *"--count"* ]]
    [[ "$j" != *"--stop-on-failure"* ]]
    [[ "$j" != *"--json-summary"* ]]
    [[ "$j" == *"--max-inflight 1"* ]]
}

# ---------- detached: launch command per backend ----------

@test "tmux launch argv tees the child to the log" {
    local -a l
    _knit_drain_launch_argv l tmux sess /tmp/x.log "CMD --max-inflight 2"
    [ "${l[0]}" = tmux ]
    [ "${l[1]}" = new-session ]
    [ "${l[2]}" = -d ]
    [ "${l[3]}" = -s ]
    [ "${l[4]}" = sess ]
    [ "${l[5]}" = "CMD --max-inflight 2 2>&1 | tee /tmp/x.log" ]
}

@test "screen launch argv runs the child under bash -lc" {
    local -a l
    _knit_drain_launch_argv l screen sess /tmp/x.log "CMD"
    [ "${l[0]}" = screen ]
    [ "${l[1]}" = -dmS ]
    [ "${l[2]}" = sess ]
    [ "${l[3]}" = bash ]
    [ "${l[4]}" = -lc ]
    [ "${l[5]}" = "CMD 2>&1 | tee /tmp/x.log" ]
}

@test "nohup launch argv redirects the child to the log" {
    local -a l
    _knit_drain_launch_argv l nohup sess /tmp/x.log "CMD"
    [[ "${l[0]}" == setsid || "${l[0]}" == nohup ]]
    [ "${l[1]}" = bash ]
    [ "${l[2]}" = -c ]
    [ "${l[3]}" = "CMD > /tmp/x.log 2>&1 < /dev/null" ]
}

# ---------- detached: --when guards ----------

@test "--session without --detached is rejected" {
    knit_test_require_jq
    run knit submit drain --session foo
    [ "$status" -ne 0 ]
    [[ "$output" == *"--session"* ]]
}

@test "--log without --detached is rejected" {
    knit_test_require_jq
    run knit submit drain --log /tmp/x
    [ "$status" -ne 0 ]
    [[ "$output" == *"--log"* ]]
}

@test "--detach-backend without --detached is rejected" {
    knit_test_require_jq
    run knit submit drain --detach-backend tmux
    [ "$status" -ne 0 ]
    [[ "$output" == *"--detach_backend"* ]]
}

# ---------- detached: orchestrator (spawn stubbed, nothing really launched) ----------

@test "detach orchestrator (tmux) launches and prints reattach/stop" {
    _KNIT_SCRIPT_PATH="/x/exp.sh"
    _KNIT_PREFIX="$(mktemp -d)"
    local spawnfile
    spawnfile="$(mktemp)"
    _knit_command_path() { case "$1" in tmux) echo /usr/bin/tmux;; esac; }
    _knit_drain_spawn() { shift; printf '%s\n' "$*" > "${spawnfile}"; }
    run _knit_drain_detach auto sess false /tmp/s.log "" "" 2 "" false false
    [ "$status" -eq 0 ]
    [[ "$output" == *'tmux session "sess"'* ]]
    [[ "$output" == *"Reattach: tmux attach -t sess"* ]]
    [[ "$output" == *"Stop:     tmux kill-session -t sess"* ]]
    run cat "${spawnfile}"
    [[ "$output" == *"tmux new-session -d -s sess"* ]]
    [[ "$output" == *"tee /tmp/s.log"* ]]
    rm -f "${spawnfile}"
}

@test "detach orchestrator (nohup) reports the pid and stop hint" {
    _KNIT_SCRIPT_PATH="/x/exp.sh"
    local spawnfile
    spawnfile="$(mktemp)"
    _knit_command_path() { case "$1" in nohup|setsid) echo "/usr/bin/$1";; esac; }
    _knit_drain_spawn() { shift; printf '%s\n' "$*" > "${spawnfile}"; printf '4242\n'; }
    run _knit_drain_detach auto sess false /tmp/s.log "" "" 1 "" false false
    [ "$status" -eq 0 ]
    [[ "$output" == *"pid 4242"* ]]
    [[ "$output" == *"Stop: kill 4242"* ]]
    run cat "${spawnfile}"
    [[ "$output" == *"bash -c"* ]]
    [[ "$output" == *"> /tmp/s.log 2>&1"* ]]
    rm -f "${spawnfile}"
}

@test "detach orchestrator warns that nohup ignores an explicit --session" {
    _KNIT_SCRIPT_PATH="/x/exp.sh"
    local spawnfile
    spawnfile="$(mktemp)"
    _knit_command_path() { case "$1" in nohup) echo /usr/bin/nohup;; esac; }
    _knit_drain_spawn() { shift; printf '%s\n' "$*" > "${spawnfile}"; printf '1\n'; }
    run _knit_drain_detach nohup mysess true /tmp/s.log "" "" 1 "" false false
    [ "$status" -eq 0 ]
    [[ "$output" == *"--session is ignored"* ]]
    rm -f "${spawnfile}"
}

@test "submit drain --detached threads through to a background session" {
    _KNIT_SCRIPT_PATH="/x/exp.sh"
    _KNIT_PREFIX="$(mktemp -d)"
    local spawnfile
    spawnfile="$(mktemp)"
    _knit_command_path() { case "$1" in tmux) echo /usr/bin/tmux;; esac; }
    _knit_drain_spawn() { shift; printf '%s\n' "$*" > "${spawnfile}"; }
    run _knit_submit_drain --detached true --max-inflight 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"Draining in the background"* ]]
    run cat "${spawnfile}"
    [[ "$output" == *"tmux new-session"* ]]
    [[ "$output" == *"submit drain"* ]]
    [[ "$output" == *"--max-inflight 2"* ]]
    rm -f "${spawnfile}"
}

# ---------- dispatch (--max-inflight 0 / 1 / N reach the right mode) ----------

@test "submit drain --max-inflight 3 dispatches to the pool" {
    _drain_program a:0 b:0 c:0 d:0
    run _knit_submit_drain --max-inflight 3
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 4 job(s): 4 completed, 0 failed."* ]]
}

@test "submit drain dispatches to serial by default" {
    _drain_program a:0 b:0
    run _knit_submit_drain
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 2 job(s): 2 completed, 0 failed."* ]]
}

@test "submit drain --max-inflight 0 dispatches to no-limit" {
    _drain_program a:0 b:0
    run _knit_submit_drain --max-inflight 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released 2 job(s)."* ]]
    [[ "$output" != *"completed"* ]]
}
