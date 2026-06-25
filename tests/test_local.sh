#!/usr/bin/env bats

setup() {
    source knit.sh
    TMPDIR_LOCAL="$(mktemp -d)"
}

teardown() {
    rm -rf "${TMPDIR_LOCAL}"
}

# ---------- __knit_walltime_to_seconds ----------

@test "__knit_walltime_to_seconds converts 00:00:01 to 1" {
    run __knit_walltime_to_seconds "00:00:01"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "__knit_walltime_to_seconds converts 00:01:00 to 60" {
    run __knit_walltime_to_seconds "00:01:00"
    [ "$status" -eq 0 ]
    [ "$output" = "60" ]
}

@test "__knit_walltime_to_seconds converts 01:00:00 to 3600" {
    run __knit_walltime_to_seconds "01:00:00"
    [ "$status" -eq 0 ]
    [ "$output" = "3600" ]
}

@test "__knit_walltime_to_seconds converts 24:00:00 to 86400" {
    run __knit_walltime_to_seconds "24:00:00"
    [ "$status" -eq 0 ]
    [ "$output" = "86400" ]
}

@test "__knit_walltime_to_seconds handles leading zeros without octal interpretation" {
    run __knit_walltime_to_seconds "00:08:09"
    [ "$status" -eq 0 ]
    [ "$output" = "489" ]
}

# ---------- _knit_submit_local ----------

@test "_knit_submit_local returns a numeric PID" {
    run _knit_submit_local -- sleep 10
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    kill "$output" 2>/dev/null || true
}

@test "_knit_submit_local redirects stdout to file" {
    local out="${TMPDIR_LOCAL}/out.txt"
    local pid
    pid="$(_knit_submit_local --stdout "${out}" -- bash -c 'printf hello')"
    _knit_wait_local "${pid}"
    run cat "${out}"
    [ "$output" = "hello" ]
}

@test "_knit_submit_local accepts options in --name=value form" {
    local out="${TMPDIR_LOCAL}/out.txt"
    local pid
    pid="$(_knit_submit_local --stdout="${out}" -- bash -c 'printf hello')"
    _knit_wait_local "${pid}"
    run cat "${out}"
    [ "$output" = "hello" ]
}

@test "_knit_submit_local redirects stderr to file" {
    local err="${TMPDIR_LOCAL}/err.txt"
    local pid
    pid="$(_knit_submit_local --stderr "${err}" -- bash -c 'printf oops >&2')"
    _knit_wait_local "${pid}"
    run cat "${err}"
    [ "$output" = "oops" ]
}

@test "_knit_submit_local reads stdin from file" {
    local inp="${TMPDIR_LOCAL}/in.txt"
    local out="${TMPDIR_LOCAL}/out.txt"
    printf 'from stdin' > "${inp}"
    local pid
    pid="$(_knit_submit_local --stdin "${inp}" --stdout "${out}" -- cat)"
    _knit_wait_local "${pid}"
    run cat "${out}"
    [ "$output" = "from stdin" ]
}

@test "_knit_submit_local discards stdout when --stdout is not given" {
    local flag="${TMPDIR_LOCAL}/flag"
    local pid
    pid="$(_knit_submit_local -- bash -c "touch \"${flag}\"")"
    _knit_wait_local "${pid}"
    [ -f "${flag}" ]
}

@test "_knit_submit_local kills command after walltime elapses" {
    local pid
    pid="$(_knit_submit_local --walltime "00:00:01" -- sleep 60)"
    sleep 2
    run kill -0 "${pid}"
    [ "$status" -ne 0 ]
}

@test "_knit_submit_local fails on unknown option" {
    run _knit_submit_local --bad-option -- echo hi
    [ "$status" -ne 0 ]
}

@test "_knit_submit_local fails on a stray positional argument before --" {
    run _knit_submit_local stray -- echo hi
    [ "$status" -ne 0 ]
}

@test "_knit_submit_local fails when no command is given after --" {
    run _knit_submit_local --stdout /dev/null
    [ "$status" -ne 0 ]
}

@test "_knit_submit_local fails on invalid walltime format" {
    run _knit_submit_local --walltime "99:99" -- echo hi
    [ "$status" -ne 0 ]
}

# ---------- _knit_wait_local ----------

@test "_knit_wait_local waits until the process finishes" {
    local out="${TMPDIR_LOCAL}/out.txt"
    local pid
    pid="$(_knit_submit_local --stdout "${out}" -- bash -c 'sleep 0.5; printf done')"
    _knit_wait_local "${pid}"
    run cat "${out}"
    [ "$output" = "done" ]
}

@test "_knit_wait_local returns immediately for an already-finished process" {
    local pid
    pid="$(_knit_submit_local -- true)"
    sleep 0.2
    run _knit_wait_local "${pid}"
    [ "$status" -eq 0 ]
}

@test "_knit_wait_local fails on empty PID" {
    run _knit_wait_local ""
    [ "$status" -ne 0 ]
}

@test "_knit_wait_local fails on non-numeric PID" {
    run _knit_wait_local "notapid"
    [ "$status" -ne 0 ]
}
