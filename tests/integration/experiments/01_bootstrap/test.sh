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
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Run bootstrap
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-01"

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

assert_summary
