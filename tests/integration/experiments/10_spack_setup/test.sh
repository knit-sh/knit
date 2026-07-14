#!/usr/bin/env bash
# Integration test 10_spack_setup.
#
# Bootstrap provisions the knit-private Spack (a git clone, comparable in cost to
# the from-source sqlite build the other tests already do), so this runs as part
# of the normal suite.
#
# Exercises:
#   - bootstrap auto-provisions the knit-private Spack because a registered setup
#     declares a Spack environment (knit_with_spack_specs) — even without --spack
#   - knit_with_spack_specs builds + activates a Spack env as the setup's first
#     step
#   - .activate.sh carries a `spack env activate` block
#   - the setup DB row captures __spack_yaml__/__spack_lock__ provenance
#   - the `knit spack` wrapper works and sees the installed zlib
#   - a job requiring the setup re-hydrates the Spack env and sees zlib
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/10_spack_setup/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/10-spack-setup-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/10_spack_setup/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap. A registered setup declares a Spack environment, so bootstrap
# provisions the knit-private Spack automatically (no --spack needed). This
# clones Spack and can take several minutes.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-10"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

check_file ".knit/spack/bin/spack" \
    "bootstrap auto-provisioned the private Spack (setup requires it)"

# --------------------------------------------------------------------------
# Build the Spack-backed setup. knit writes spack.yaml, installs the env, and
# activates it; the setup body then runs with zlib on the environment.
# --------------------------------------------------------------------------
./experiment.sh setup --path "${WORKDIR}/zenv" -- zlibenv

check_file "zenv/.activate.sh" "setup produced .activate.sh"
check_grep "spack env activate" "zenv/.activate.sh" \
    ".activate.sh re-activates the Spack environment"

# Provenance: the setup row captured the concrete manifest + lockfile. The table
# name contains a colon, so it is bracket-quoted for SQLite.
check_sqlite ".knit/knit.db" \
    "SELECT LENGTH(__spack_yaml__) > 0 FROM [setup:zlibenv];" \
    "1" \
    "setup row captured __spack_yaml__ provenance"
check_sqlite ".knit/knit.db" \
    "SELECT LENGTH(__spack_lock__) > 0 FROM [setup:zlibenv];" \
    "1" \
    "setup row captured __spack_lock__ provenance"

# --------------------------------------------------------------------------
# The `knit spack` wrapper works and sees the installed zlib.
# --------------------------------------------------------------------------
if ./experiment.sh spack find zlib >/dev/null 2>&1; then
    __assert_pass "knit spack find zlib succeeds"
else
    fail "knit spack find zlib failed"
fi

# --------------------------------------------------------------------------
# Submit a job that requires the setup; it must re-hydrate the Spack env.
# --------------------------------------------------------------------------
uuid=$(./experiment.sh submit --setup "${WORKDIR}/zenv" --wait -- zcheck)

jobdir=$(find "${WORKDIR}/zenv/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "${jobdir}" ]] || fail "no job directory created under zenv/jobs"

check_eq "${uuid}" "$(basename "${jobdir}")" \
    "submit prints the job UUID (the job directory name)"

# --wait blocks until completion, but guard against output-flush lag.
for _ in $(seq 1 30); do
    [[ -s "${jobdir}/.stdout" ]] && break
    sleep 1
done

check_file "${jobdir}/.stdout" "job stdout captured"
check_grep "marker: zlibenv-built" "${jobdir}/.stdout" \
    "job inherited the setup's exported marker"
check_grep "spack_env: .*/spack-env" "${jobdir}/.stdout" \
    "job re-activated the Spack environment (SPACK_ENV set)"
check_grep "zlib: found" "${jobdir}/.stdout" \
    "job sees the Spack-provided zlib"

assert_summary
