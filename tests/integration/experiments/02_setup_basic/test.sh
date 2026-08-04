#!/usr/bin/env bash
# Integration test 02_setup_basic.
#
# Exercises:
#   - knit bootstrap
#   - knit_register_setup / knit setup (full lifecycle)
#   - .activate.sh generation and correctness
#   - SQLite recording of setup parameters
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/02_setup_basic/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/02-setup-basic-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/02_setup_basic/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-02"

export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

# --------------------------------------------------------------------------
# Run the setup
# --------------------------------------------------------------------------
./experiment.sh setup --name my-env -- basic --message "Hello from knit"

# --------------------------------------------------------------------------
# Assertions: directory structure
# --------------------------------------------------------------------------
check_dir  "setups/my-env"               "setup directory created"
check_file "setups/my-env/greeting.txt"  "greeting.txt written by setup function"
check_file "setups/my-env/.activate.sh"  ".activate.sh generated"
check_exec "setups/my-env/.activate.sh"  ".activate.sh is executable"

# --------------------------------------------------------------------------
# Assertions: greeting.txt content
# --------------------------------------------------------------------------
check_grep "Hello from knit" "setups/my-env/greeting.txt" \
    "greeting.txt contains the message parameter"

# --------------------------------------------------------------------------
# Assertions: .activate.sh captures exported variable
# --------------------------------------------------------------------------
check_grep "MY_GREETING" "setups/my-env/.activate.sh" \
    ".activate.sh contains MY_GREETING"
check_grep "Hello.*from.*knit" "setups/my-env/.activate.sh" \
    ".activate.sh contains the greeting value"

# KNIT_SETUP_PREFIX must NOT appear in .activate.sh (it is excluded by design).
if grep -q "KNIT_SETUP_PREFIX" "setups/my-env/.activate.sh"; then
    fail "KNIT_SETUP_PREFIX must not appear in .activate.sh"
else
    __assert_pass "KNIT_SETUP_PREFIX excluded from .activate.sh"
fi

# --------------------------------------------------------------------------
# Assertions: database table was created (run recording is a future feature)
# --------------------------------------------------------------------------
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='setup:basic';" \
    "1" \
    "DB has a table for setup:basic"

# --------------------------------------------------------------------------
# Assertions: provenance edges
#
# The top-level `knit setup` dispatcher is table-less, but it is still a
# visible command, so it records a root edge (empty source columns) — coverage
# a table-presence-based design could not provide. The setup body then records
# a "setup -> setup:basic" call edge whose target joins the setup:basic table.
# --------------------------------------------------------------------------
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM __provenance__ WHERE source_id='' AND source_name='' AND target_name='setup' AND edge_type='call';" \
    "1" \
    "top-level setup dispatcher records a root edge (empty source)"

check_sqlite ".knit/knit.db" \
    "SELECT source_name FROM __provenance__ WHERE target_name='setup:basic' AND edge_type='call';" \
    "setup" \
    "setup body records a 'setup -> setup:basic' call edge"

# The body edge's target id is the setup body's row id, which joins the
# setup:basic table (one row).
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM __provenance__ e JOIN [setup:basic] s ON s.id=e.target_id WHERE e.target_name='setup:basic' AND e.edge_type='call';" \
    "1" \
    "setup body edge target joins the setup:basic data row"

assert_summary
