#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # Start from a clean run/job environment so nothing leaks between tests.
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    unset KNIT_MPI_RANK KNIT_MPI_SIZE KNIT_MPI_LOCAL_RANK
    unset "${!KNIT_CHECKSUM_@}" 2>/dev/null || true
    _KNIT_RECORDING_SUPPRESSED=""
    KNIT_SCRIPT_PATH="./exp.sh"

    # An app with a checksummed file input, a checksummed directory input, and a
    # file input that opted out of the digest. All optional (empty default) so a
    # test may leave any of them unset.
    _ck_app_fn() { :; }
    knit_register_app "myapp" "_ck_app_fn" "A checksum test app."
    knit_with_optional "data:file" "" "Input data file."
    knit_with_optional "dir:directory" "" "Input data directory."
    knit_with_optional "aux:file" "" "Auxiliary file (no digest)." --no-checksum
    knit_done

    SUBCMD="$(_knit_command_mangle "run:myapp")"
}

teardown() {
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    unset "${!KNIT_CHECKSUM_@}" 2>/dev/null || true
    _KNIT_RECORDING_SUPPRESSED=""
    knit_test_db_teardown
}

# Stub the launch machinery so the dispatcher runs to completion without a real
# launcher. _knit_launch_exec records the forwarded checksum environment it sees
# (it runs inside the launch subshell, so this proves the digest was exported).
_stub_dispatch() {
    knit_job_hostnames() { printf '%s\n' "nodeA"; }
    _knit_metadata_get() { local -n __r=$1; __r=''; }
    _knit_launch_backend() { local -n __r=$1; __r='none'; }
    _knit_launch_cmdline() { local -n _argv="$3"; _argv=(launcher); }
    _knit_launch_exec() {
        printf '%s' "${KNIT_CHECKSUM_data:-UNSET}" \
            > "${BATS_TEST_TMPDIR}/forwarded_data"
        touch "${BATS_TEST_TMPDIR}/launched"
        return 0
    }
    _knit_uuidv7() { printf '%s' "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"; }
}

# ---------- _knit_run_checksum_inputs: login-side hashing ----------

@test "dispatcher hashes an existing file input to its digest" {
    local file="${BATS_TEST_TMPDIR}/in.txt"
    printf 'payload\n' > "${file}"
    local expected
    _knit_sha256 expected "${file}"

    declare -A digests=()
    _knit_run_checksum_inputs digests "${SUBCMD}" --data "${file}"

    [ "${digests[data]}" = "${expected}" ]
}

@test "dispatcher hashes a directory input recursively" {
    local dir="${BATS_TEST_TMPDIR}/indir"
    mkdir -p "${dir}/sub"
    printf 'a\n' > "${dir}/a.txt"
    printf 'b\n' > "${dir}/sub/b.txt"
    local expected
    _knit_sha256 expected "${dir}"

    declare -A digests=()
    _knit_run_checksum_inputs digests "${SUBCMD}" --dir "${dir}"

    [ "${digests[dir]}" = "${expected}" ]
}

@test "dispatcher checks existence but records no digest for a --no-checksum input" {
    local file="${BATS_TEST_TMPDIR}/aux.txt"
    printf 'x\n' > "${file}"

    declare -A digests=()
    _knit_run_checksum_inputs digests "${SUBCMD}" --aux "${file}"

    # Existence held (no fatal), but the opted-out input contributes no digest.
    [ ! -v digests[aux] ]
}

@test "dispatcher skips an absent optional input" {
    declare -A digests=()
    run _knit_run_checksum_inputs digests "${SUBCMD}"
    [ "$status" -eq 0 ]
}

@test "dispatcher fatals on a missing checksummed input" {
    declare -A digests=()
    run _knit_run_checksum_inputs digests "${SUBCMD}" --data /no/such/file
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "dispatcher fatals on a missing --no-checksum input too" {
    declare -A digests=()
    run _knit_run_checksum_inputs digests "${SUBCMD}" --aux /no/such/aux
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
}

# ---------- dispatcher end to end: hash once, forward, fail fast ----------

@test "dispatcher hashes the input once and forwards it to the launcher" {
    _stub_dispatch
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    local file="${BATS_TEST_TMPDIR}/in.txt"
    printf 'payload\n' > "${file}"
    local expected
    _knit_sha256 expected "${file}"

    _knit_invoke_command run --procs 1 -- myapp --data "${file}"

    # The launch subshell saw KNIT_CHECKSUM_data set to the bare digest.
    [ "$(cat "${BATS_TEST_TMPDIR}/forwarded_data")" = "${expected}" ]
}

@test "dispatcher fails fast before launching on a missing input" {
    _stub_dispatch
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"

    run _knit_invoke_command run --procs 1 -- myapp --data /no/such/file
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
    # The launcher must never have been reached.
    [ ! -e "${BATS_TEST_TMPDIR}/launched" ]
}

# ---------- app-worker context: ranks never hash ----------

@test "_knit_checksum_is_app_worker is true for an app under a live run" {
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    _knit_checksum_is_app_worker "${SUBCMD}"
}

@test "_knit_checksum_is_app_worker is false without a run id" {
    unset KNIT_RUN_ID
    ! _knit_checksum_is_app_worker "${SUBCMD}"
}

@test "_knit_checksum_is_app_worker is false for a non-app command" {
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    ! _knit_checksum_is_app_worker "$(_knit_command_mangle "run")"
}

@test "the worker input hook stashes the forwarded digest without hashing" {
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    # A sentinel digest that is deliberately NOT the file's real hash; if the hook
    # recomputed from disk it would differ.
    export KNIT_CHECKSUM_data="0000000000000000000000000000000000000000000000000000000000000000"
    local file="${BATS_TEST_TMPDIR}/in.txt"
    printf 'payload\n' > "${file}"

    declare -gA "_KNIT_CMD_${SUBCMD}_output_value=()"
    _knit_checksum_inputs "${SUBCMD}" --data "${file}"

    local -n ov="_KNIT_CMD_${SUBCMD}_output_value"
    [ "${ov[data_checksum]}" = "sha256:${KNIT_CHECKSUM_data}" ]
}

@test "rank 0 records the forwarded input digest" {
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    export KNIT_CHECKSUM_data="0000000000000000000000000000000000000000000000000000000000000000"
    _knit_uuidv7() { printf '%s' "bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb"; }
    local file="${BATS_TEST_TMPDIR}/in.txt"
    printf 'payload\n' > "${file}"

    # Rank 0 re-enters the app command directly (as the worker does).
    _knit_invoke_command run myapp --data "${file}"

    run sqlite3 "${_KNIT_DATABASE}" "SELECT data, data_checksum FROM myapp;"
    [ "$output" = "${file}|sha256:${KNIT_CHECKSUM_data}" ]
}
