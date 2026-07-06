#!/usr/bin/env bats

setup() {
    source knit.sh
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
}

# ---------- lifecycle wrappers delegate to the local backend ----------

@test "none_directives forwards to the local directives" {
    _knit_sched_local_directives() { printf 'D:%s\n' "$*" > "${_KNIT_TEST_TMPDIR}/o"; }
    _knit_sched_none_directives arr jd
    [ "$(< "${_KNIT_TEST_TMPDIR}/o")" = "D:arr jd" ]
}

@test "none_submit forwards to the local submit" {
    _knit_sched_local_submit() { printf 'S:%s\n' "$*" > "${_KNIT_TEST_TMPDIR}/o"; }
    _knit_sched_none_submit arr script jd
    [ "$(< "${_KNIT_TEST_TMPDIR}/o")" = "S:arr script jd" ]
}

@test "none_wait forwards to the local wait" {
    _knit_sched_local_wait() { printf 'W:%s\n' "$*" > "${_KNIT_TEST_TMPDIR}/o"; }
    _knit_sched_none_wait 4242
    [ "$(< "${_KNIT_TEST_TMPDIR}/o")" = "W:4242" ]
}

@test "none_cancel forwards to the local cancel" {
    _knit_sched_local_cancel() { printf 'C:%s\n' "$*" > "${_KNIT_TEST_TMPDIR}/o"; }
    _knit_sched_none_cancel 4242
    [ "$(< "${_KNIT_TEST_TMPDIR}/o")" = "C:4242" ]
}

# ---------- _knit_sched_none_hostfile ----------

@test "none_hostfile prints the configured nodefile verbatim (blank lines dropped)" {
    local nf="${_KNIT_TEST_TMPDIR}/nodes"
    printf 'nodeA\nnodeA:4\n\nnodeB\n' > "${nf}"
    _knit_metadata_load() { printf '%s\n' "${nf}"; }

    run _knit_sched_none_hostfile
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[0]}" = "nodeA" ]
    [ "${lines[1]}" = "nodeA:4" ]
    [ "${lines[2]}" = "nodeB" ]
}

@test "none_hostfile falls back to the local hostname when no nodefile is configured" {
    _knit_metadata_load() { printf '\n'; }
    run _knit_sched_none_hostfile
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(hostname)"* ]]
}

@test "none_hostfile falls back to the local hostname when the nodefile is unreadable" {
    _knit_metadata_load() { printf '%s\n' "${_KNIT_TEST_TMPDIR}/does-not-exist"; }
    run _knit_sched_none_hostfile
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(hostname)"* ]]
}
