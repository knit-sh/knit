#!/usr/bin/env bash
# Driver for types.sh (not shown in the documentation). Bootstraps the experiment
# and exercises every type feature the Types page introduces: type-annotated
# parameters (accepted values and rejected mismatches), a manual knit_type_check,
# and a user-defined enum used as a parameter type.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project types-demo --scheduler local >/dev/null

# resize: typed parameters accept matching values...
check_eq "$(exp resize --width 800)" "width=800 factor=1.0" \
    "typed parameters accept matching values"
check_eq "$(exp resize --width 800 --factor 0.5)" "width=800 factor=0.5" \
    "a real-typed optional parameter accepts a decimal"

# ...and reject a mismatched value before the body runs.
if bad="$(exp resize --width big 2>&1)"; then
    check_eq "ran" "rejected" "an integer parameter must reject a non-integer"
else
    check_contains "${bad}" 'expects a value of type "integer"' \
        "the type mismatch is reported"
fi

# budget: knit_type_check validates a value by hand.
check_eq "$(exp budget --amount 3.14)" "3.14 is a number" \
    "knit_type_check accepts a valid real"
check_eq "$(exp budget --amount lots)" "lots is not a number" \
    "knit_type_check rejects a non-number"

# convert: an enum type accepts a defined value...
check_eq "$(exp convert --to jpeg)" "converting to jpeg" \
    "the enum type accepts a defined value"

# ...and rejects anything else, listing the accepted values.
if bad="$(exp convert --to gif 2>&1)"; then
    check_eq "ran" "rejected" "the enum type must reject an undefined value"
else
    check_contains "${bad}" "expects one of: png, jpeg, webp" \
        "the enum error lists the accepted values"
fi

# report: a file input and file/directory outputs, with content checksums.
printf 'a\nb\nc\n' > data.txt
exp report --input data.txt >/dev/null

# The input's path and a sha256 of its content are recorded.
check_eq "$(exp query sql --exec "SELECT input FROM report;")" "data.txt" \
    "the file input records its path"
check_contains "$(exp query sql --exec "SELECT input_checksum FROM report;")" \
    "sha256:" "the file input records a content checksum"

# The checksummed file output records its path and a sha256 too.
check_eq "$(exp query sql --exec "SELECT summary FROM report;")" "summary.txt" \
    "the file output records its path"
check_contains "$(exp query sql --exec "SELECT summary_checksum FROM report;")" \
    "sha256:" "the file output records a content checksum"

# The --no-checksum directory output records its path but has no checksum column.
check_eq "$(exp query sql --exec "SELECT workdir FROM report;")" "work" \
    "the --no-checksum output records its path"
if exp query sql --exec "SELECT workdir_checksum FROM report;" >/dev/null 2>&1; then
    check_eq "column present" "no column" \
        "a --no-checksum output has no checksum column"
else
    check_eq "no column" "no column" \
        "a --no-checksum output has no checksum column"
fi

# A missing file input is rejected before the body runs.
if bad="$(exp report --input nope.txt 2>&1)"; then
    check_eq "ran" "rejected" "a missing file input must be rejected"
else
    check_contains "${bad}" "does not exist" "the missing input is reported"
fi

dc_summary
