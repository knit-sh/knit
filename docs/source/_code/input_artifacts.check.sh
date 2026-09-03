#!/usr/bin/env bash
# Driver for input_artifacts.sh (not shown in the documentation). Bootstraps the
# experiment, produces a kinded (csvfile) artifact, consumes it by kind with
# --verify-checksum, and asserts the recorded kind, the consumed row count, the
# used_by edge, and the full produced -> used_by lineage. It also confirms the
# two refusals the consumer promises: a kind mismatch and a changed table.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project input-artifacts >/dev/null

# tabulate: produce the CSV table as a csvfile artifact (a result).
exp tabulate >/dev/null
check_eq "$([[ -f artifacts/table.csv ]] && echo yes)" "yes" \
    "tabulate writes artifacts/table.csv"

# The artifact records the physical type AND the semantic kind.
row="$(exp query sql --exec \
    "SELECT type, kind FROM artifacts WHERE path='table.csv'" \
    2>/dev/null | tr -d '[:space:]')"
check_contains "${row}" "file" "artifacts row records the physical type"
check_contains "${row}" "csvfile" "artifacts row records the semantic kind"

# summarize: consume the csvfile artifact by kind and count its data rows.
check_eq "$(exp summarize --table table.csv)" "summarize: 3 data rows" \
    "summarize reads the artifact through knit_input_artifact_path"
check_contains "$(exp query sql --exec 'SELECT rows FROM summarize' \
    2>/dev/null | tr -d '[:space:]')" "3" "summarize records rows=3"

# The consume left a used_by edge from the artifact's row to the consumer,
# completing tabulate --produced--> table --used_by--> summarize. One SQL join
# over the two edges recovers the whole lineage.
lineage="$(exp query sql --exec \
    "SELECT pr.source_name || '->' || ub.target_name
       FROM artifacts a
       JOIN __provenance__ pr ON pr.target_id = a.id AND pr.edge_type = 'produced'
       JOIN __provenance__ ub ON ub.source_id = a.id AND ub.edge_type = 'used_by'
      WHERE a.path = 'table.csv'" 2>/dev/null | tr -d '[:space:]')"
check_eq "${lineage}" "tabulate->summarize" \
    "the produced and used_by edges walk tabulate -> table -> summarize"

# Kind mismatch: record a plain-file artifact, then point the consumer at it.
# It is a "file", not a "csvfile", so the consumer refuses it.
exp note >/dev/null
check_contains "$(exp query sql --exec \
    "SELECT kind FROM artifacts WHERE path='note.txt'" \
    2>/dev/null | tr -d '[:space:]')" "file" "note records the bare file kind"
if exp summarize --table note.txt >/dev/null 2>&1; then
    check_eq "consumed" "refused" "summarize must refuse a non-csvfile artifact"
else
    check_eq "refused" "refused" "summarize refuses a kind mismatch"
fi

# Checksum mismatch: a table changed since it was produced is refused.
printf '4,16\n' >> artifacts/table.csv
if exp summarize --table table.csv >/dev/null 2>&1; then
    check_eq "consumed" "refused" \
        "summarize --verify-checksum must refuse a changed table"
else
    check_eq "refused" "refused" \
        "summarize --verify-checksum refuses a changed table"
fi

dc_summary
