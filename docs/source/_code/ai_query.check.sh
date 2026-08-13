#!/usr/bin/env bash
# Driver for ai_query.sh (not shown in the documentation). Bootstraps the
# experiment and records a montecarlo run, then confirms the `ai query` builtin
# is wired up. The actual question-answering needs a live provider, so we only
# assert the table it queries exists and that `ai query --help` runs.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project ai-query >/dev/null

# Record a run so the `montecarlo` table `ai query` writes SQL against exists.
check_eq "$(exp montecarlo --samples 1000)" "samples=1000 pi=3.14159" \
    "montecarlo prints its estimate"
row="$(exp query sql --exec 'SELECT samples FROM montecarlo LIMIT 1' \
    2>/dev/null | tr -d '[:space:]')"
check_contains "${row}" "1000" "montecarlo records samples=1000"

# `ai query --help` is served by the CLI framework before any provider lookup,
# so it works with no key configured and proves the command (and its --lang /
# --format / --query-only options) is registered.
help="$(exp ai query --help 2>&1)"
check_contains "${help}" "--lang" "ai query exposes --lang"
check_contains "${help}" "--query-only" "ai query exposes --query-only"

dc_summary
