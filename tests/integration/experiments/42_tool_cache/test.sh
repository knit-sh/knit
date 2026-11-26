#!/usr/bin/env bash
# Integration test 42_tool_cache.
#
# Exercises the shared framework-tool cache (sqlite, jq, knit-cypher-to-sql,
# knit-pilotd) under ~/.cache/knit/tools:
#   - a first bootstrap builds the tools from source / downloads them and
#     populates the cache (both the source and the built layers);
#   - the provisioned ".knit" is removed, keeping only the warm cache;
#   - a second bootstrap with KNIT_OFFLINE=1 re-provisions purely from the cache,
#     with no network, and the reinstalled tools run.
#
# The cache is isolated under the work directory via XDG_CACHE_HOME, so the test
# never touches the user's real ~/.cache. The first bootstrap builds from source
# (no --use-system-*), which is what populates the cache; the offline second
# bootstrap proves a warm cache makes re-provisioning network-free.
#
# Expected outcomes:
#   - the first bootstrap populates built/ and sources/ entries in the cache
#   - the offline second bootstrap succeeds and recreates the tools under .knit
#   - the reinstalled sqlite runs (the new database and metadata exist)
#   - knit-pilotd reinstalled from the cache reports its version
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/42_tool_cache/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/42-tool-cache-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/42_tool_cache/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# Isolate the tool cache under the work directory (not the user's ~/.cache). The
# default _KNIT_TOOL_CACHE_ROOT is "${XDG_CACHE_HOME}/knit/tools".
export XDG_CACHE_HOME="${WORKDIR}/cache"

# --------------------------------------------------------------------------
# First bootstrap: builds the tools and populates the cache (online).
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-42" --account "test-alloc"

export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

# The build published every tool into the cache.
check_dir "cache/knit/tools/built/sqlite"        "sqlite built tree cached"
check_dir "cache/knit/tools/built/cypher-to-sql" "knit-cypher-to-sql built tree cached"
check_dir "cache/knit/tools/built/pilotd"        "knit-pilotd built tree cached"
check_dir "cache/knit/tools/sources/jq"          "jq binary cached"

# --------------------------------------------------------------------------
# Remove the provisioned tools, keep the warm cache, re-bootstrap OFFLINE.
# --------------------------------------------------------------------------
# The default setup lives under setups/ (the setup path), outside .knit, so it
# must be cleared too for a fresh bootstrap to re-instantiate it.
rm -rf .knit setups

# KNIT_OFFLINE=1 forbids every download, so this can only succeed by installing
# from the warm cache.
KNIT_OFFLINE=1 ./experiment.sh bootstrap \
    --project "integration-test-42" --account "test-alloc"

# The tools are back under .knit and executable.
check_exec ".knit/sqlite/bin/sqlite3" \
    "sqlite3 reinstalled from the cache (offline)"
check_exec ".knit/jq/bin/jq" \
    "jq reinstalled from the cache (offline)"
check_exec ".knit/knit-cypher-to-sql/bin/knit-cypher-to-sql" \
    "knit-cypher-to-sql reinstalled from the cache (offline)"
check_exec ".knit/knit-pilotd/bin/knit-pilotd" \
    "knit-pilotd reinstalled from the cache (offline)"

# The reinstalled sqlite actually runs: the offline bootstrap built the database
# and wrote metadata with it.
check_file ".knit/knit.db" ".knit/knit.db recreated by the offline bootstrap"
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__project__';" \
    "integration-test-42" \
    "the cache-installed sqlite recorded the project metadata"

# The reinstalled knit-pilotd runs (its version probe is what the built-cache
# smoke test relies on).
".knit/knit-pilotd/bin/knit-pilotd" --version > pilotd-version.txt 2>&1
check_grep "knit-pilotd" "pilotd-version.txt" \
    "knit-pilotd reinstalled from the cache reports its version"

assert_summary
