#!/usr/bin/env bash
#
# list-test-files.sh
#
# Print the bats unit-test files as a compact JSON array of basenames, e.g.
#   ["test_app.sh","test_bootstrap.sh",...]
#
# Consumed by .github/workflows/tests.yml to build a dynamic matrix with one job
# per test file: a "prep" job runs this and exposes the array as a job output,
# which the matrix reads via fromJSON. (The coverage workflow instead runs a
# fixed number of shards via maint/shard-test-files.sh, to keep the artifact
# count bounded as the suite grows.)
#
# The tests/test_*.sh glob excludes tests/setup_teardown.sh (shared helpers, not
# a test file) by construction.
#
set -euo pipefail

# Run from tests/ so the glob expands to bare basenames (no ls/basename needed),
# regardless of the caller's working directory.
cd "$(dirname "$0")/../tests"

printf '%s\n' test_*.sh | jq -R -s -c 'split("\n")[:-1]'
