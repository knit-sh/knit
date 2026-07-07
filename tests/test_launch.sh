#!/usr/bin/env bats

setup() {
    source knit.sh
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
}

# ---------- _knit_launch_backend ----------

@test "_knit_launch_backend prefers an explicit override" {
    _knit_metadata_load()   { printf 'openmpi\n'; }
    _knit_detect_launcher() { printf 'mpich\n'; }
    run _knit_launch_backend slurm
    [ "$status" -eq 0 ]
    [ "$output" = "slurm" ]
}

@test "_knit_launch_backend uses metadata when no override" {
    _knit_metadata_load()   { printf 'openmpi\n'; }
    _knit_detect_launcher() { printf 'mpich\n'; }
    run _knit_launch_backend
    [ "$output" = "openmpi" ]
}

@test "_knit_launch_backend falls back to detection when metadata is empty" {
    _knit_metadata_load()   { printf '\n'; }
    _knit_detect_launcher() { printf 'mpich\n'; }
    run _knit_launch_backend
    [ "$output" = "mpich" ]
}

@test "_knit_launch_backend maps detection's <unknown> to none" {
    _knit_metadata_load()   { printf '\n'; }
    _knit_detect_launcher() { printf '<unknown>\n'; }
    run _knit_launch_backend
    [ "$output" = "none" ]
}

@test "_knit_launch_backend maps a <unknown> metadata value to none" {
    _knit_metadata_load()   { printf '<unknown>\n'; }
    run _knit_launch_backend
    [ "$output" = "none" ]
}

# ---------- dispatcher: unknown backend ----------

@test "_knit_launch_cmdline fatals on an unknown backend" {
    declare -A opts
    run _knit_launch_cmdline bogus opts
    [ "$status" -ne 0 ]
    [[ "$output" == *"not implemented"* ]]
}

@test "_knit_launch_exec fatals on an unknown backend" {
    declare -A opts
    run _knit_launch_exec bogus opts -- true
    [ "$status" -ne 0 ]
    [[ "$output" == *"not implemented"* ]]
}

# ---------- none backend: cmdline ----------

@test "none cmdline prints an empty argv" {
    declare -A opts
    run _knit_launch_cmdline none opts
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "none cmdline rejects a multi-rank placement" {
    declare -A opts=([procs]=4)
    run _knit_launch_cmdline none opts
    [ "$status" -ne 0 ]
    [[ "$output" == *"single process"* ]]
}

# ---------- none backend: exec ----------

@test "_knit_launch_exec routes to the none backend and runs the worker" {
    declare -A opts
    run _knit_launch_exec none opts -- printf 'routed\n'
    [ "$status" -eq 0 ]
    [ "$output" = "routed" ]
}

@test "none exec runs the worker command exactly once" {
    declare -A opts
    _knit_launch_none_exec opts -- \
        bash -c 'printf "x\n" >> "'"${_KNIT_TEST_TMPDIR}"'/count"'
    [ "$(wc -l < "${_KNIT_TEST_TMPDIR}/count")" -eq 1 ]
}

@test "none exec forwards arguments to the worker" {
    declare -A opts
    run _knit_launch_none_exec opts -- printf '%s-%s\n' a b
    [ "$status" -eq 0 ]
    [ "$output" = "a-b" ]
}

@test "none exec returns the worker's exit status" {
    declare -A opts
    run _knit_launch_none_exec opts -- bash -c 'exit 3'
    [ "$status" -eq 3 ]
}

@test "none exec tolerates a missing -- separator" {
    declare -A opts
    run _knit_launch_none_exec opts printf 'noflag\n'
    [ "$status" -eq 0 ]
    [ "$output" = "noflag" ]
}

# ---------- none backend: single-local-rank validation ----------

@test "none exec accepts an explicit single local rank" {
    declare -A opts=([procs]=1 [procs-per-node]=1 [hostnames]="$(hostname)")
    run _knit_launch_none_exec opts -- printf 'ok\n'
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

@test "none exec rejects --procs greater than one" {
    declare -A opts=([procs]=2)
    run _knit_launch_none_exec opts -- printf 'never\n'
    [ "$status" -ne 0 ]
    [[ "$output" == *"--procs 2"* ]]
    [[ "$output" != *"never"* ]]
}

@test "none exec rejects --procs-per-node greater than one" {
    declare -A opts=([procs-per-node]=2)
    run _knit_launch_none_exec opts -- printf 'never\n'
    [ "$status" -ne 0 ]
    [[ "$output" == *"--procs-per-node 2"* ]]
}

@test "none exec rejects a non-local host" {
    declare -A opts=([hostnames]="some-other-host")
    run _knit_launch_none_exec opts -- printf 'never\n'
    [ "$status" -ne 0 ]
    [[ "$output" == *"local host only"* ]]
}
