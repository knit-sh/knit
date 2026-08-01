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
    _knit_metadata_get()    { local -n __r=$1; __r='openmpi'; }
    local out
    KNIT_PROVIDED_LAUNCHER=mpich _knit_launch_backend out slurm
    [ "$out" = "slurm" ]
}

@test "_knit_launch_backend uses the concrete metadata when no override" {
    _knit_metadata_get()    { local -n __r=$1; __r='openmpi'; }
    local out
    _knit_launch_backend out
    [ "$out" = "openmpi" ]
}

@test "_knit_launch_backend uses KNIT_PROVIDED_LAUNCHER when metadata is empty" {
    _knit_metadata_get()    { local -n __r=$1; __r=''; }
    local out
    KNIT_PROVIDED_LAUNCHER=mpich _knit_launch_backend out
    [ "$out" = "mpich" ]
}

@test "_knit_launch_backend skips a <unknown> metadata so the setup contract wins" {
    _knit_metadata_get()    { local -n __r=$1; __r='<unknown>'; }
    local out
    KNIT_PROVIDED_LAUNCHER=openmpi _knit_launch_backend out
    [ "$out" = "openmpi" ]
}

@test "_knit_launch_backend falls back to none when nothing is configured" {
    _knit_metadata_get()    { local -n __r=$1; __r=''; }
    local out
    KNIT_PROVIDED_LAUNCHER='' _knit_launch_backend out
    [ "$out" = "none" ]
}

@test "_knit_launch_backend maps a <unknown> metadata value to none with no contract" {
    _knit_metadata_get()    { local -n __r=$1; __r='<unknown>'; }
    local out
    KNIT_PROVIDED_LAUNCHER='' _knit_launch_backend out
    [ "$out" = "none" ]
}

@test "_knit_launch_backend does not call _knit_detect_launcher at run time" {
    _knit_metadata_get()    { local -n __r=$1; __r=''; }
    # Fail loudly if run-time detection is (re)introduced.
    _knit_detect_launcher() { printf 'SHOULD_NOT_BE_CALLED\n'; }
    local out
    KNIT_PROVIDED_LAUNCHER='' _knit_launch_backend out
    [ "$out" = "none" ]
    [ "$out" != "SHOULD_NOT_BE_CALLED" ]
}

# ---------- _knit_launch_bind_value: normalized binding vocabulary ----------

@test "bind value maps the OpenMPI/Hydra family (openmpi/mpich/pbs)" {
    local v
    _knit_launch_bind_value v openmpi none;   [ "$v" = "none" ]
    _knit_launch_bind_value v openmpi core;   [ "$v" = "core" ]
    _knit_launch_bind_value v mpich socket;   [ "$v" = "socket" ]
    _knit_launch_bind_value v pbs numa;       [ "$v" = "numa" ]
    # A hardware thread is spelled hwthread across this family.
    _knit_launch_bind_value v openmpi thread; [ "$v" = "hwthread" ]
    _knit_launch_bind_value v mpich thread;   [ "$v" = "hwthread" ]
}

@test "bind value maps the Slurm spellings" {
    local v
    _knit_launch_bind_value v slurm none;   [ "$v" = "none" ]
    _knit_launch_bind_value v slurm core;   [ "$v" = "cores" ]
    _knit_launch_bind_value v slurm socket; [ "$v" = "sockets" ]
    _knit_launch_bind_value v slurm numa;   [ "$v" = "ldoms" ]
    _knit_launch_bind_value v slurm thread; [ "$v" = "threads" ]
}

@test "bind value maps the PALS spellings" {
    local v
    _knit_launch_bind_value v pals none;   [ "$v" = "none" ]
    _knit_launch_bind_value v pals core;   [ "$v" = "core" ]
    _knit_launch_bind_value v pals socket; [ "$v" = "socket" ]
    _knit_launch_bind_value v pals numa;   [ "$v" = "numa" ]
    _knit_launch_bind_value v pals thread; [ "$v" = "thread" ]
}

@test "bind value passes an unknown value through verbatim with a warning" {
    local v
    run _knit_launch_bind_value v slurm map_ldom:0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unknown --bind value"* ]]
    [[ "$output" == *"map_ldom:0"* ]]
}

@test "bind value of an unknown value is exactly the value returned" {
    # The warning goes to stderr; the verbatim value is written to the nameref.
    local out
    _knit_launch_bind_value out openmpi weird 2>/dev/null
    [ "${out}" = "weird" ]
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

@test "none cmdline produces an empty argv" {
    declare -A opts
    declare -a argv=(sentinel)
    _knit_launch_cmdline none opts argv
    [ "${#argv[@]}" -eq 0 ]
}

@test "none cmdline rejects a multi-rank placement" {
    declare -A opts=([procs]=4)
    declare -a argv
    run _knit_launch_cmdline none opts argv
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
