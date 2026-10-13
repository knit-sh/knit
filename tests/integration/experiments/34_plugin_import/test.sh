#!/usr/bin/env bash
# Integration test 34_plugin_import.
#
# Exercises:
#   - knit_import fetching a plugin live from github.com (ref -> commit via the
#     host API, tarball download, checksum verify, cache, source)
#   - bootstrap recording the plugin: the committed knit-plugins.lock, the
#     "plugins" provenance table row, and the materialized tree under
#     .knit/plugins/<host>/<org>/<repo>/
#   - running a command the plugin defines (template hello), including its
#     decorator banner and its write under the .knit directory
#
# Needs network access to github.com (api.github.com + codeload). GITHUB_TOKEN,
# when present, is forwarded by the integration Makefile to avoid the anonymous
# rate limit.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/34_plugin_import/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

EXP_DIR="/shared/knit/tests/integration/experiments/34_plugin_import"

WORKDIR=$(mktemp -d /shared/runs/34-plugin-import-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp "${EXP_DIR}/experiment.sh" "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

PLUGIN_ID="github.com/knit-sh/knit-template-plugin"

# --------------------------------------------------------------------------
# Bootstrap. knit_import runs at source time (before the bootstrap command),
# so the plugin is fetched here; bootstrap then records and materializes it.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-34"

export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

check_dir  ".knit"            ".knit directory created"
check_file ".knit/knit.db"    ".knit/knit.db file created"

# --------------------------------------------------------------------------
# The committed lockfile pins the plugin.
# --------------------------------------------------------------------------
check_file "knit-plugins.lock"                "knit-plugins.lock written"
check_grep "${PLUGIN_ID}" "knit-plugins.lock" "lockfile pins the plugin"

# --------------------------------------------------------------------------
# The plugins table records one row for the plugin, with a resolved commit.
# --------------------------------------------------------------------------
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM plugins WHERE repo='knit-template-plugin';" \
    "1" \
    "plugins table records the imported plugin"

check_sqlite ".knit/knit.db" \
    "SELECT CASE WHEN \"commit\" <> '' THEN 'yes' ELSE 'no' END FROM plugins WHERE repo='knit-template-plugin';" \
    "yes" \
    "the recorded plugin has a resolved commit"

# imported_by is empty: the experiment imported the plugin directly.
check_sqlite ".knit/knit.db" \
    "SELECT CASE WHEN imported_by = '' THEN 'experiment' ELSE imported_by END FROM plugins WHERE repo='knit-template-plugin';" \
    "experiment" \
    "the plugin was imported by the experiment"

# --------------------------------------------------------------------------
# The pinned tree is materialized under .knit for a self-contained directory.
# --------------------------------------------------------------------------
check_file ".knit/plugins/${PLUGIN_ID}/plugin.sh" \
    "plugin tree materialized under .knit/plugins"

# --------------------------------------------------------------------------
# A command the plugin defines runs (cache hit; no network this time).
# --------------------------------------------------------------------------
HELLO_OUT=$(./experiment.sh template hello --name Grace)
check_grep "Hello, Grace!" <(printf '%s\n' "${HELLO_OUT}") \
    "the imported command greets"
check_grep "=== template plugin ===" <(printf '%s\n' "${HELLO_OUT}") \
    "the decorator banner runs before the command"

# The command wrote under the .knit directory via knit_prefix.
check_file ".knit/template-plugin/greeted.log" \
    "the imported command wrote under .knit"
check_grep "Grace" ".knit/template-plugin/greeted.log" \
    "the greeted name was logged"

assert_summary
