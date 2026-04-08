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
./experiment.sh setup --path ./my-env -- basic --message "Hello from knit"

# --------------------------------------------------------------------------
# Assertions: directory structure
# --------------------------------------------------------------------------
check_dir  "my-env"               "setup directory created"
check_file "my-env/greeting.txt"  "greeting.txt written by setup function"
check_file "my-env/.activate.sh"  ".activate.sh generated"
check_exec "my-env/.activate.sh"  ".activate.sh is executable"

# --------------------------------------------------------------------------
# Assertions: greeting.txt content
# --------------------------------------------------------------------------
check_grep "Hello from knit" "my-env/greeting.txt" \
    "greeting.txt contains the message parameter"

# --------------------------------------------------------------------------
# Assertions: .activate.sh captures exported variable
# --------------------------------------------------------------------------
check_grep "MY_GREETING" "my-env/.activate.sh" \
    ".activate.sh contains MY_GREETING"
check_grep "Hello.*from.*knit" "my-env/.activate.sh" \
    ".activate.sh contains the greeting value"

# KNIT_SETUP_PREFIX must NOT appear in .activate.sh (it is excluded by design).
if grep -q "KNIT_SETUP_PREFIX" "my-env/.activate.sh"; then
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

assert_summary
