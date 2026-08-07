#!/usr/bin/env bats

# Tests for knit_provides_launcher: the setup directive that detects an MPI
# launcher once at setup-build time and freezes it as the KNIT_PROVIDED_LAUNCHER
# contract in the setup's .activate.sh.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}"
    _test_setup_fn() { :; }
    # A pre-existing .activate.sh with a platform block, as the generic setup
    # after-callback would have written it before this after-callback appends.
    _seed_activate() {
        {
            printf '#!/usr/bin/env bash\n'
            printf '# Platform activation (inlined)\n'
            printf 'export PLATFORM_SEEDED=1\n'
        } > "${KNIT_SETUP_PREFIX}/.activate.sh"
    }
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    unset KNIT_SETUP_PREFIX
    knit_test_db_teardown
}

# ---------- knit_provides_launcher: registration ----------

@test "knit_provides_launcher declares the __mpi_launcher__ column" {
    knit_register_setup "mpienv" "_test_setup_fn" "Build MPI."
    knit_provides_launcher
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('setup:mpienv');" \
        | cut -d'|' -f2 | tr '\n' ',')
    [[ "${names}" == *__mpi_launcher__* ]]
}

@test "a setup without the directive has no __mpi_launcher__ column" {
    knit_register_setup "plain" "_test_setup_fn" "Plain setup."
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('setup:plain');" \
        | cut -d'|' -f2 | tr '\n' ',')
    [[ "${names}" != *__mpi_launcher__* ]]
}

@test "knit_provides_launcher records a --help note" {
    knit_register_setup "mpienv" "_test_setup_fn" "Build MPI."
    knit_provides_launcher
    knit_done
    local result
    result=$(_knit_invoke_command "setup" "mpienv" "--help")
    [[ "${result}" == *"Provides an MPI launcher"* ]]
}

@test "knit_provides_launcher installs its after callback after the generic dump" {
    knit_register_setup "mpienv" "_test_setup_fn" "Build MPI."
    knit_provides_launcher
    knit_done
    local cmd
    cmd=$(_knit_command_mangle "setup:mpienv")
    local -a cbs
    eval "cbs=(\"\${_KNIT_CMD_${cmd}_after_cb[@]}\")"
    # The generic dump truncates .activate.sh and must run first; the launcher
    # contract appends and must run after.
    [[ "${cbs[0]}" == *_knit_setup_after_cb* ]]
    [[ "${cbs[-1]}" == *_knit_setup_provides_launcher_after_cb* ]]
}

# ---------- knit_provides_launcher: validation ----------

@test "knit_provides_launcher is fatal outside a setup registration" {
    run knit_provides_launcher
    [ "$status" -ne 0 ]
    [[ "$output" == *"only for setups"* ]]
}

@test "knit_provides_launcher is fatal on a non-setup command" {
    knit_register "plaincmd" _test_setup_fn "A plain command."
    run knit_provides_launcher
    [ "$status" -ne 0 ]
    [[ "$output" == *"only for setups"* ]]
    knit_done
}

@test "knit_provides_launcher is fatal when declared twice" {
    knit_register_setup "mpienv" "_test_setup_fn" "Build MPI."
    knit_provides_launcher
    run knit_provides_launcher
    [ "$status" -ne 0 ]
    [[ "$output" == *"at most once"* ]]
}

# ---------- _knit_setup_provides_launcher_after_cb ----------

# Register a real setup so __mpi_launcher__ is a declared output, then simulate
# the mid-invocation state knit_output needs (the command on the executing stack
# with an output-value map). Mirrors the spack after-callback tests.
_arm_cmd() {
    knit_register_setup "mpienv" "_test_setup_fn" "Build MPI."
    knit_provides_launcher
    knit_done
    _ARMED_CMD=$(_knit_command_mangle "setup:mpienv")
    declare -gA "_KNIT_CMD_${_ARMED_CMD}_output_value=()"
    _KNIT_EXECUTING_COMMAND=("${_ARMED_CMD}")
}

@test "the after callback clears the detection cache before detecting" {
    _seed_activate
    _arm_cmd
    # A stale cache value must not leak in: the callback clears it first. The stub
    # reports what it observed (detection runs in a $(...) subshell, so it signals
    # back through its return value rather than a variable).
    _KNIT_DETECTED_LAUNCHER="stale"
    _knit_detect_launcher() {
        if [[ -z "${_KNIT_DETECTED_LAUNCHER}" ]]; then
            printf 'openmpi\n'
        else
            printf 'stale-leaked\n'
        fi
    }
    _knit_setup_provides_launcher_after_cb
    grep -q 'export KNIT_PROVIDED_LAUNCHER=openmpi' "${KNIT_SETUP_PREFIX}/.activate.sh"
}

@test "the after callback freezes KNIT_PROVIDED_LAUNCHER below the platform block" {
    _seed_activate
    _arm_cmd
    _knit_detect_launcher() { printf 'mpich\n'; }
    _knit_setup_provides_launcher_after_cb
    local f="${KNIT_SETUP_PREFIX}/.activate.sh"
    grep -q 'export KNIT_PROVIDED_LAUNCHER=mpich' "${f}"
    # The contract is appended after the pre-existing platform block.
    local plat_line contract_line
    plat_line="$(grep -n 'PLATFORM_SEEDED' "${f}" | head -1 | cut -d: -f1)"
    contract_line="$(grep -n 'KNIT_PROVIDED_LAUNCHER' "${f}" | head -1 | cut -d: -f1)"
    [ "${plat_line}" -lt "${contract_line}" ]
}

@test "the after callback records the detected launcher as __mpi_launcher__ provenance" {
    _seed_activate
    _arm_cmd
    _knit_detect_launcher() { printf 'mpich\n'; }
    _knit_setup_provides_launcher_after_cb
    local -n _out_ref="_KNIT_CMD_${_ARMED_CMD}_output_value"
    [ "${_out_ref[__mpi_launcher__]}" = "mpich" ]
}

@test "the frozen contract activates as a real export" {
    _seed_activate
    _arm_cmd
    _knit_detect_launcher() { printf 'openmpi\n'; }
    _knit_setup_provides_launcher_after_cb
    # A consumer sourcing .activate.sh gets the contract in its environment.
    local got
    got="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${KNIT_PROVIDED_LAUNCHER}"' _ "${KNIT_SETUP_PREFIX}/.activate.sh")"
    [ "${got}" = "openmpi" ]
}

@test "the after callback is fatal when no launcher is found, writing nothing" {
    _seed_activate
    _knit_detect_launcher() { printf '<unknown>\n'; }
    run _knit_setup_provides_launcher_after_cb
    [ "$status" -ne 0 ]
    [[ "$output" == *"no MPI launcher found"* ]]
    # Nothing is appended to .activate.sh on the fatal path.
    ! grep -q 'KNIT_PROVIDED_LAUNCHER' "${KNIT_SETUP_PREFIX}/.activate.sh"
}
