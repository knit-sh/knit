#!/usr/bin/env bash
# Integration test 01_bootstrap.
#
# Exercises:
#   - knit bootstrap (sqlite build from source, DB creation, initial metadata)
#
# Expected outcomes:
#   - .knit/ directory is created
#   - .knit/knit.db exists and is a valid SQLite database
#   - The metadata table contains at least one row (the project name entry)
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/01_bootstrap/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

# Locate the sqlite3 binary knit built (bootstrap puts it at .knit/sqlite/bin/sqlite3).
# We set __ASSERT_SQLITE3 after bootstrap completes.

# Create an isolated working directory for this test run.
WORKDIR=$(mktemp -d /shared/runs/01-bootstrap-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/01_bootstrap/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Run bootstrap
# --------------------------------------------------------------------------
# No --profile / --default-cpus-per-node, so the per-node core count is filled
# by live detection (sinfo/pbsnodes/flux resource). Every cluster advertises 2
# CPUs per node (the CI runner exposes only 2 cores, so the Flux inventory
# declares 2 to match — see docker/flux/conf/flux/system.toml).
./experiment.sh bootstrap --project "integration-test-01" --account "test-alloc"
EXPECTED_NCPUS="2"

# Point the assertion helper at the sqlite3 built by knit.
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------
check_dir ".knit"                          ".knit directory created"
check_file ".knit/knit.db"                 ".knit/knit.db file created"
check_exec ".knit/sqlite/bin/sqlite3"      "sqlite3 binary is executable"

check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM metadata WHERE key='__project__';" \
    "1" \
    "metadata table has project entry"

# The --account flag is stored as __account__.
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__account__';" \
    "test-alloc" \
    "metadata stores the account from --account"

# The per-node core count was detected from the live scheduler.
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__node_ncpus__';" \
    "${EXPECTED_NCPUS}" \
    "metadata stores the detected per-node core count"

assert_summary
