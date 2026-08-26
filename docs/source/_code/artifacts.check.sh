#!/usr/bin/env bash
# Driver for artifacts.sh (not shown in the documentation). Bootstraps the
# experiment, exercises the result and artifact commands, and asserts the
# recorded row values, the checksums, and the on-disk artifacts/ layout.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project artifacts >/dev/null

# measure: a value output marked --result, plus a plain output.
check_eq "$(exp measure --x 5)" "square=25" "measure prints the square"
sq="$(exp query sql --exec 'SELECT square FROM measure WHERE x = 5' \
    2>/dev/null | tr -d '[:space:]')"
check_contains "${sq}" "25" "measure records square=25"

# tabulate: a direct-write artifact plus a value result.
exp tabulate >/dev/null
check_eq "$([[ -f artifacts/table.csv ]] && echo yes)" "yes" \
    "tabulate writes artifacts/table.csv"
trow="$(exp query sql --exec 'SELECT "table", table_checksum, rows FROM tabulate' \
    2>/dev/null | tr -d '[:space:]')"
check_contains "${trow}" "table.csv" "tabulate records the artifacts-relative path"
check_contains "${trow}" "sha256:" "tabulate records the table checksum"
check_contains "${trow}" "3" "tabulate records rows=3"

# collect: --copy-from makes a real file, --link-from makes a symlink.
exp collect >/dev/null
check_eq "$([[ -f artifacts/figure.svg && ! -L artifacts/figure.svg ]] && echo yes)" \
    "yes" "collect copies figure.svg in as a real file"
check_eq "$([[ -L artifacts/dataset.dat ]] && echo yes)" "yes" \
    "collect links dataset.dat as a symlink"
crow="$(exp query sql --exec 'SELECT figure, dataset, dataset_checksum FROM collect' \
    2>/dev/null | tr -d '[:space:]')"
check_contains "${crow}" "figure.svg" "collect records the copied artifact path"
check_contains "${crow}" "dataset.dat" "collect records the linked artifact path"
check_contains "${crow}" "sha256:" "collect checksums the linked target"

dc_summary
