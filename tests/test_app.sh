#!/usr/bin/env bats

setup() {
    source knit.sh
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    # Default allocation (8 hosts) and per-node core count (4) for the placement
    # resolver; individual tests override these stubs as needed.
    knit_job_hostnames() { printf 'h0\nh1\nh2\nh3\nh4\nh5\nh6\nh7\n'; }
    _knit_metadata_load() { printf '4\n'; }
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    unset KNIT_JOB_PREFIX
}

# ---------- run command registration ----------

@test "run command is registered" {
    _knit_set_find _KNIT_COMMANDS "run"
}

@test "run command uses the \"Apps\" subcommand title" {
    [ "${_KNIT_CMD_run_sucommand_title}" = "Apps" ]
}

@test "run command is a dispatcher with the \"app\" placeholder" {
    [ "${_KNIT_CMD_run_dispatch}" = "app" ]
}

@test "run command records into the \"runs\" table" {
    [ "${_KNIT_CMD_run_table}" = "runs" ]
}

@test "_run worker command is registered and hidden" {
    _knit_set_find _KNIT_COMMANDS "_run"
    [ "${_KNIT_CMD__run_is_hidden}" = "true" ]
}

# ---------- knit_register_app ----------

@test "knit_register_app adds name to _KNIT_APPS" {
    _app_fn() { :; }
    knit_register_app "myapp" "_app_fn" "A test app."
    knit_done
    [[ -v _KNIT_APPS["myapp"] ]]
}

@test "knit_register_app registers run:<name> command" {
    _app_fn() { :; }
    knit_register_app "myapp" "_app_fn" "A test app."
    knit_done
    _knit_set_find _KNIT_COMMANDS "run__1__myapp"
}

@test "knit_register_app installs the app before-callback" {
    _app_fn() { :; }
    knit_register_app "myapp" "_app_fn" "A test app."
    knit_done
    local -n _cbs="_KNIT_CMD_run__1__myapp_before_cb"
    [[ " ${_cbs[*]} " == *"_knit_app_before_cb"* ]]
}

# ---------- dispatcher guards ----------

@test "run fatals when invoked outside a job" {
    _app_fn() { :; }
    knit_register_app "myapp" "_app_fn" "A test app."
    knit_done
    run _knit_invoke_command run -- myapp
    [ "$status" -ne 0 ]
    [[ "$output" == *"KNIT_JOB_PREFIX"* ]]
}

@test "run fatals when no app name is given after --" {
    export KNIT_JOB_PREFIX="${_KNIT_TEST_TMPDIR}/job"
    run _knit_invoke_command run --procs 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires an app name"* ]]
}

@test "run fatals on an unknown app" {
    export KNIT_JOB_PREFIX="${_KNIT_TEST_TMPDIR}/job"
    run _knit_invoke_command run -- nosuchapp
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown app"* ]]
}

@test "app before-callback fatals when invoked outside a job" {
    unset KNIT_JOB_PREFIX
    run _knit_app_before_cb
    [ "$status" -ne 0 ]
    [[ "$output" == *"knit run"* ]]
}

# ---------- placement resolver ----------

@test "placement: --procs and --procs-per-node fill the first nodes" {
    declare -A place
    _knit_run_resolve_placement place --procs 32 --procs-per-node 4
    [ "${place[procs]}" = "32" ]
    [ "${place[procs-per-node]}" = "4" ]
    [ "${place[hostnames]}" = "h0,h1,h2,h3,h4,h5,h6,h7" ]
}

@test "placement: --procs with --hostnames derives procs-per-node" {
    declare -A place
    _knit_run_resolve_placement place --procs 8 --hostnames h0,h1
    [ "${place[procs]}" = "8" ]
    [ "${place[procs-per-node]}" = "4" ]
    [ "${place[hostnames]}" = "h0,h1" ]
}

@test "placement: --procs-per-node with --hostnames derives procs" {
    declare -A place
    _knit_run_resolve_placement place --procs-per-node 4 --hostnames h0,h1
    [ "${place[procs]}" = "8" ]
    [ "${place[procs-per-node]}" = "4" ]
    [ "${place[hostnames]}" = "h0,h1" ]
}

@test "placement: --procs alone spreads over the allocation (no procs-per-node)" {
    declare -A place
    _knit_run_resolve_placement place --procs 16
    [ "${place[procs]}" = "16" ]
    [ "${place[procs-per-node]}" = "" ]
    [ "${place[hostnames]}" = "h0,h1,h2,h3,h4,h5,h6,h7" ]
}

@test "placement: --hostnames alone fills each node by the core count" {
    declare -A place
    _knit_run_resolve_placement place --hostnames h0,h1
    [ "${place[procs]}" = "8" ]
    [ "${place[procs-per-node]}" = "4" ]
    [ "${place[hostnames]}" = "h0,h1" ]
}

@test "placement: no options fills the whole allocation" {
    declare -A place
    _knit_run_resolve_placement place
    [ "${place[procs]}" = "32" ]
    [ "${place[procs-per-node]}" = "4" ]
    [ "${place[hostnames]}" = "h0,h1,h2,h3,h4,h5,h6,h7" ]
}

@test "placement: unknown core count falls back to one rank per node" {
    _knit_metadata_load() { printf '\n'; }
    declare -A place
    _knit_run_resolve_placement place
    [ "${place[procs]}" = "8" ]
    [ "${place[procs-per-node]}" = "" ]
    [ "${place[hostnames]}" = "h0,h1,h2,h3,h4,h5,h6,h7" ]
}

# ---------- placement resolver: conflicts ----------

@test "placement conflict: procs/procs-per-node needs more nodes than --hostnames lists" {
    run _knit_run_resolve_placement place --procs 32 --procs-per-node 4 --hostnames h0,h1
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs 8 nodes"* ]]
}

@test "placement conflict: procs not divisible by procs-per-node" {
    run _knit_run_resolve_placement place --procs 30 --procs-per-node 4
    [ "$status" -ne 0 ]
    [[ "$output" == *"not divisible"* ]]
}

@test "placement conflict: a --hostnames host is not in the allocation" {
    run _knit_run_resolve_placement place --hostnames h0,nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"not in the job's allocation"* ]]
}

@test "placement conflict: procs not divisible by the --hostnames count" {
    run _knit_run_resolve_placement place --procs 7 --hostnames h0,h1
    [ "$status" -ne 0 ]
    [[ "$output" == *"not divisible"* ]]
}

# ---------- worker ----------

@test "worker routes to the app body" {
    _app_fn() { printf 'ran n=%s\n' "$(knit_get_parameter n "$@")" > "${_KNIT_TEST_TMPDIR}/out"; }
    knit_register_app "myapp" "_app_fn" "A test app."
    knit_with_optional "n:integer" "1" "Problem size."
    knit_done
    export KNIT_JOB_PREFIX="${_KNIT_TEST_TMPDIR}/job"
    _knit_run_worker -- myapp --n 5
    [ "$(cat "${_KNIT_TEST_TMPDIR}/out")" = "ran n=5" ]
}

@test "worker fatals when no app name is given after --" {
    run _knit_run_worker --
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires an app name"* ]]
}

# ---------- dispatcher exec wiring ----------

@test "run execs the worker command under the resolved launcher backend" {
    _app_fn() { :; }
    knit_register_app "myapp" "_app_fn" "A test app."
    knit_done
    export KNIT_JOB_PREFIX="${_KNIT_TEST_TMPDIR}/job"
    _knit_launch_backend() { printf 'openmpi\n'; }
    _knit_launch_exec() { printf 'EXEC %s\n' "$*"; }
    run _knit_invoke_command run --procs 2 -- myapp
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXEC openmpi"* ]]
    [[ "$output" == *"_run -- myapp"* ]]
}

@test "run records the app name as an output" {
    _app_fn() { :; }
    knit_register_app "myapp" "_app_fn" "A test app."
    knit_done
    export KNIT_JOB_PREFIX="${_KNIT_TEST_TMPDIR}/parent-job-uuid"
    _knit_launch_backend() { printf 'none\n'; }
    # _knit_run builds the launcher argv (for the native_cmd column) before
    # launching; stub it too so the over-specified `none` placement is not rejected.
    _knit_launch_cmdline() { local -n _argv="$3"; _argv=(launcher); }
    _knit_launch_exec() { :; }
    _knit_invoke_command run --procs 2 -- myapp
    [ "${_KNIT_CMD_run_output_value[app]}" = "myapp" ]
}
