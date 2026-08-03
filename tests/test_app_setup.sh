#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _knit_create_metadata_table

    # Start from a clean run/job environment so nothing leaks between tests.
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SETUP_PREFIX MC_SEED
    unset KNIT_MPI_RANK KNIT_MPI_SIZE KNIT_MPI_LOCAL_RANK
    _KNIT_RECORDING_SUPPRESSED=""
    KNIT_SCRIPT_PATH="./exp.sh"

    # Pin the experiment root so a --setup name resolves under
    # <experiment-root>/setups. KNIT_TEST_SETUP_DIR is a setup instance named
    # KNIT_TEST_SETUP_NAME there: tests reference it by name via --setup, or by
    # path when standing it up directly as the ambient KNIT_SETUP_PREFIX (whose
    # .activate.sh must NOT be re-sourced by the worker).
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    KNIT_TEST_SETUP_NAME="seedenv"
    KNIT_TEST_SETUP_DIR="${_KNIT_TEST_TMPDIR}/setups/${KNIT_TEST_SETUP_NAME}"
    mkdir -p "${KNIT_TEST_SETUP_DIR}"
}

teardown() {
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SETUP_PREFIX MC_SEED
    _KNIT_RECORDING_SUPPRESSED=""
    [[ -n "${_KNIT_TEST_TMPDIR:-}" ]] && rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

# Register an app whose only option defaults to an ENV[...] value, so a recorded
# row lets us observe exactly which environment the app resolved against.
_register_seeded_app() {
    _seed_app_fn() { :; }
    knit_register_app "seeded" "_seed_app_fn" "An app with an ENV[...] default."
    knit_with_optional "seed:integer" "ENV[MC_SEED]" "Random seed."
    knit_done
}

# ---------- the worker inherits the forwarded env, it does NOT re-source ----------

@test "the worker does not re-source .activate.sh (the job's env modifications win)" {
    # The setup's activation script would set a different value and leave a marker
    # if it ran; the worker must run neither.
    local marker="${KNIT_TEST_SETUP_DIR}/sourced.marker"
    { printf 'export MC_SEED=1\n'; printf 'touch %q\n' "${marker}"; } \
        > "${KNIT_TEST_SETUP_DIR}/.activate.sh"

    _register_seeded_app

    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    export KNIT_SETUP_PREFIX="${KNIT_TEST_SETUP_DIR}"
    # The job set up MC_SEED=1 originally, then overrode it before `knit run`; the
    # launcher forwards this live value to the rank.
    export MC_SEED=2

    _knit_run_worker -- seeded

    # The app must see the forwarded value (2), not the setup's original (1)...
    run sqlite3 "${_KNIT_DATABASE}" "SELECT seed FROM seeded;"
    [ "$output" = "2" ]
    # ...and .activate.sh must never have run.
    [ ! -f "${marker}" ]
}

# ---------- ENV[...] option defaults resolve from the forwarded environment ----------

@test "an ENV[...] app-option default resolves from the forwarded environment" {
    _register_seeded_app

    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    # No KNIT_SETUP_PREFIX: the value reaches the rank purely by env forwarding.
    export MC_SEED=1234

    _knit_run_worker -- seeded

    run sqlite3 "${_KNIT_DATABASE}" "SELECT seed FROM seeded;"
    [ "$output" = "1234" ]
}

@test "the worker runs with no setup environment present" {
    _setup_app_fn() { :; }
    knit_register_app "myapp" "_setup_app_fn" "A setup-less test app."
    knit_done

    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    # KNIT_SETUP_PREFIX intentionally unset.

    run _knit_run_worker -- myapp
    [ "$status" -eq 0 ]
}

# ---------- knit_with_setup is allowed on an app registration ----------

@test "knit_with_setup on an app installs a --setup option and a before-callback" {
    _setup_app_fn() { :; }
    knit_register_app "myapp" "_setup_app_fn" "A test app."
    knit_with_setup "mcenv"
    knit_done
    [ "${_KNIT_CMD_run__1__myapp_setup}" = "mcenv" ]
    _knit_set_find "_KNIT_CMD_run__1__myapp_optional" "setup"
    # The generic setup-dependency callback runs after the app's own
    # KNIT_JOB_PREFIX guard.
    local -n _cbs="_KNIT_CMD_run__1__myapp_before_cb"
    [[ "${_cbs[*]}" == *"_knit_app_before_cb"* ]]
    [[ "${_cbs[*]}" == *"_knit_setup_dep_before_cb"* ]]
}

@test "an app declaring knit_with_setup re-sources the given setup" {
    printf 'mcenv\n' > "${KNIT_TEST_SETUP_DIR}/.setup.type"
    printf 'export MC_SEED=7\n' > "${KNIT_TEST_SETUP_DIR}/.activate.sh"

    _seed_app_fn() { :; }
    knit_register_app "seeded" "_seed_app_fn" "An app that depends on a setup."
    knit_with_setup "mcenv"
    knit_done

    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    unset KNIT_SETUP_PREFIX MC_SEED

    _knit_run_worker -- seeded --setup "${KNIT_TEST_SETUP_NAME}"

    # The before-callback sourced the setup's .activate.sh in this shell.
    [ "${MC_SEED}" = "7" ]
}

@test "an app declaring knit_with_setup rejects a wrong-type setup" {
    printf 'otherenv\n' > "${KNIT_TEST_SETUP_DIR}/.setup.type"
    printf 'export MC_SEED=7\n' > "${KNIT_TEST_SETUP_DIR}/.activate.sh"

    _seed_app_fn() { :; }
    knit_register_app "seeded" "_seed_app_fn" "An app that depends on a setup."
    knit_with_setup "mcenv"
    knit_done

    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    unset KNIT_SETUP_PREFIX MC_SEED

    run _knit_run_worker -- seeded --setup "${KNIT_TEST_SETUP_NAME}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mcenv"* ]]
    [[ "$output" == *"otherenv"* ]]
}
