#!/usr/bin/env bats

# End-to-end wiring test for scheduler.queue_as.
#
# The directive emission (_knit_sched_slurm_directives) and the profile
# resolution (_knit_sched_resolve) are unit-tested in isolation in
# test_sched_slurm.sh and test_sched.sh. This test proves the two halves are
# wired together through the real `prepare` path: a profile that sets
# queue_as:"qos" must make `prepare` freeze a Slurm .job.sh whose queue is
# emitted as `#SBATCH --qos=` and never `#SBATCH --partition=`.
#
# No live Slurm is needed: `prepare` freezes the jobscript without contacting the
# scheduler, so the Slurm backend is forced purely by the detected-manager stub.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    _KNIT_TEST_TMPDIR="$(mktemp -d)"

    # Experiment root: jobs land under <root>/jobs, setups under <root>/setups.
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    _KNIT_TEST_SETUP_ROOT="${_KNIT_TEST_TMPDIR}/setups"
    KNIT_SCRIPT_PATH="/fake/exp.sh"

    # Force the Slurm backend without a real scheduler. `prepare` freezes the
    # jobscript and never calls sbatch, so no Slurm binary is required.
    _KNIT_DETECTED_JOB_MANAGER="slurm"

    _knit_create_metadata_table
    # prepare records into the jobs table but does not own it; create it up front.
    _knit_db_setup_table "submit" "jobs"

    # A profile that renders the queue as a QOS on Slurm (the field read goes
    # through __profile_json__, exactly as bootstrap stores it).
    _knit_metadata_store --key "__profile__" --value "inline"
    _knit_metadata_store --key "__profile_json__" --value \
        '{"scheduler":{"type":"slurm","queue_as":"qos"}}'

    # prepare must never dispatch.
    _knit_submit_local() { printf 'DISPATCHED\n' >&2; return 1; }

    # The "hello" job declares no setup, so it adopts the builtin "default" setup
    # (platform activation) that bootstrap normally instantiates. Seed a minimal
    # one at the default path.
    local defdir="${_KNIT_TEST_SETUP_ROOT}/default"
    mkdir -p "${defdir}"
    printf 'default\n' > "${defdir}/.setup.type"
    printf 'deadbeef-dead-7ead-8ead-deaddeaddead\n' > "${defdir}/.setup.id"
    printf '#!/usr/bin/env bash\n' > "${defdir}/.activate.sh"

    _hello_fn() { :; }
    knit_register_job "hello" _hello_fn "Print nothing; only its jobscript matters."
    knit_done
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    _KNIT_DETECTED_JOB_MANAGER=""
    knit_test_db_teardown
}

_jobdir() {
    find "${_KNIT_TEST_TMPDIR}/jobs" -mindepth 1 -maxdepth 1 -type d | head -1
}

@test "queue_as=qos: prepare freezes a Slurm .job.sh with --qos and no --partition" {
    local uuid
    uuid="$(_knit_invoke_command prepare \
        --nodes 1 --queue regular --walltime 00:10:00 -- hello)"
    knit_type_check "uuid" "${uuid}"

    local script
    script="$(_jobdir)/.job.sh"
    [ -f "${script}" ]

    grep -q '#SBATCH --qos=regular' "${script}"
    ! grep -q '#SBATCH --partition=' "${script}"
}
