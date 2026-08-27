#!/usr/bin/env bash
# Driver for artifacts.sh (not shown in the documentation). Bootstraps the
# experiment, exercises the result and artifact commands, and asserts the
# artifacts-table rows, the produced edges (the reverse lookup), the checksums,
# and the on-disk artifacts/ layout.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project artifacts >/dev/null

# measure: a value output marked --result, plus a plain output. A value result
# stays a column of the producing table (only artifacts move out).
check_eq "$(exp measure --x 5)" "square=25" "measure prints the square"
sq="$(exp query sql --exec 'SELECT square FROM measure WHERE x = 5' \
    2>/dev/null | tr -d '[:space:]')"
check_contains "${sq}" "25" "measure records square=25"

# tabulate: a direct-write artifact plus a value result.
exp tabulate >/dev/null
check_eq "$([[ -f artifacts/table.csv ]] && echo yes)" "yes" \
    "tabulate writes artifacts/table.csv"

# The value result is a column of the producing table; the artifact is NOT.
check_contains "$(exp query sql --exec 'SELECT rows FROM tabulate' \
    2>/dev/null | tr -d '[:space:]')" "3" "tabulate records rows=3"
cols="$(exp query sql --exec "SELECT name FROM pragma_table_info('tabulate')" \
    2>/dev/null)"
check_eq "$(printf '%s\n' "${cols}" | grep -c '^table$')" "0" \
    "the producing table has no artifact column"

# The artifact lives in the artifacts table: one row per produced artifact.
trow="$(exp query sql --exec \
    "SELECT name, type, path, result, checksum FROM artifacts WHERE path='table.csv'" \
    2>/dev/null | tr -d '[:space:]')"
check_contains "${trow}" "table.csv" "artifacts row records the artifacts-relative path"
check_contains "${trow}" "file" "artifacts row records the type"
check_contains "${trow}" "sha256:" "artifacts row records the checksum"

# Reverse lookup: which invocation produced artifacts/table.csv? Follow the
# produced edge from the artifact back to its producing row.
producer="$(exp query sql --exec \
    "SELECT p.source_name FROM artifacts a
       JOIN __provenance__ p ON p.target_id = a.id AND p.edge_type = 'produced'
      WHERE a.path = 'table.csv'" 2>/dev/null | tr -d '[:space:]')"
check_eq "${producer}" "tabulate" "the produced edge recovers the producer"

# collect: --copy-from makes a real file, --link-from makes a symlink.
exp collect >/dev/null
check_eq "$([[ -f artifacts/figure.svg && ! -L artifacts/figure.svg ]] && echo yes)" \
    "yes" "collect copies figure.svg in as a real file"
check_eq "$([[ -L artifacts/dataset.dat ]] && echo yes)" "yes" \
    "collect links dataset.dat as a symlink"

# Both bound files become artifacts rows, checksummed from the resolved target.
frow="$(exp query sql --exec \
    "SELECT path, result FROM artifacts WHERE path='figure.svg'" \
    2>/dev/null | tr -d '[:space:]')"
check_contains "${frow}" "figure.svg" "collect records the copied artifact"
drow="$(exp query sql --exec \
    "SELECT path, result, checksum FROM artifacts WHERE path='dataset.dat'" \
    2>/dev/null | tr -d '[:space:]')"
check_contains "${drow}" "dataset.dat" "collect records the linked artifact"
check_contains "${drow}" "sha256:" "collect checksums the linked target"

dc_summary
