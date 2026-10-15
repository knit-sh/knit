#!/usr/bin/env bash
# Integration test 35_uv_setup.
#
# Bootstrap provisions the knit-private uv (a single prebuilt-binary download,
# cheaper than the from-source sqlite build the other tests already do), so this
# runs as part of the normal suite.
#
# Exercises:
#   - bootstrap auto-provisions the knit-private uv because a registered setup
#     declares a uv environment (knit_with_uv_specs) — even without --uv
#   - knit_with_uv_specs builds + activates a uv venv as the setup's first step
#   - .activate.sh carries a `.venv/bin/activate` source line
#   - the setup DB row captures __uv_manifest__/__uv_lock__ provenance
#   - the `knit uv` wrapper works
#   - a job requiring the setup re-hydrates the uv venv and imports six
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/35_uv_setup/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/35-uv-setup-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/35_uv_setup/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap. A registered setup declares a uv environment, so bootstrap
# provisions the knit-private uv automatically (no --uv needed). This downloads
# a single prebuilt uv binary for the host platform.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-35"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

check_file ".knit/uv/bin/uv" \
    "bootstrap auto-provisioned the private uv (setup requires it)"

# --------------------------------------------------------------------------
# Build the uv-backed setup. knit writes pyproject.toml, syncs the env, and
# activates it; the setup body then runs with the venv on PATH.
# --------------------------------------------------------------------------
./experiment.sh setup --name penv -- pyenv

check_file "setups/penv/.activate.sh" "setup produced .activate.sh"
check_grep ".venv/bin/activate" "setups/penv/.activate.sh" \
    ".activate.sh re-activates the uv venv"

# Provenance: the setup row captured the concrete manifest + lockfile. The table
# name contains a colon, so it is bracket-quoted for SQLite.
check_sqlite ".knit/knit.db" \
    "SELECT LENGTH(__uv_manifest__) > 0 FROM [setup:pyenv];" \
    "1" \
    "setup row captured __uv_manifest__ provenance"
check_sqlite ".knit/knit.db" \
    "SELECT LENGTH(__uv_lock__) > 0 FROM [setup:pyenv];" \
    "1" \
    "setup row captured __uv_lock__ provenance"

# --------------------------------------------------------------------------
# The `knit uv` wrapper works (forwards to the provisioned uv binary).
# --------------------------------------------------------------------------
if ./experiment.sh uv --version >/dev/null 2>&1; then
    __assert_pass "knit uv --version succeeds"
else
    fail "knit uv --version failed"
fi

# --------------------------------------------------------------------------
# Submit a job that requires the setup; it must re-hydrate the uv venv.
# --------------------------------------------------------------------------
uuid=$(./experiment.sh submit --setup penv --wait -- pycheck)

jobdir=$(find "${WORKDIR}/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "${jobdir}" ]] || fail "no job directory created under jobs"

check_eq "${uuid}" "$(basename "${jobdir}")" \
    "submit prints the job UUID (the job directory name)"

# --wait blocks until completion, but guard against output-flush lag.
for _ in $(seq 1 30); do
    [[ -s "${jobdir}/.stdout" ]] && break
    sleep 1
done

check_file "${jobdir}/.stdout" "job stdout captured"
check_grep "marker: pyenv-built" "${jobdir}/.stdout" \
    "job inherited the setup's declared marker"
check_grep "venv: .*/uv-env/.venv" "${jobdir}/.stdout" \
    "job re-activated the uv venv (VIRTUAL_ENV set)"
check_grep "six: found" "${jobdir}/.stdout" \
    "job imports the uv-provided six"

# --------------------------------------------------------------------------
# Assertions: provenance "used_by" edge (a job referencing a setup it did not
# create). See 10_spack_setup for the full rationale of the edge shape; the
# target is named for the "submit" dispatcher that owns the "jobs" table.
# --------------------------------------------------------------------------
setup_id=$(cat "${WORKDIR}/setups/penv/.setup.id")
check_file "${WORKDIR}/setups/penv/.setup.id" "setup recorded its row id in .setup.id"
check_sqlite ".knit/knit.db" \
    "SELECT source_id, source_name, target_id, target_name, start_time, end_time FROM __provenance__ WHERE edge_type='used_by';" \
    "${setup_id}|setup:pyenv|${uuid}|submit||" \
    "used_by edge links the setup (source_id == .setup.id) to the job, NULL times"

assert_summary
