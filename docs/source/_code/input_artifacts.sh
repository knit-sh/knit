#!/bin/bash

# A small experiment showing artifact KINDS and consuming an artifact by kind.
# "csvfile" is a semantic kind backed by the physical file type: `tabulate`
# produces a csvfile artifact and `summarize` consumes it, re-verifying its
# checksum. Kept to the local backend so it runs anywhere with bash + sqlite3.

source knit.sh

knit_set_program_description "Artifact kinds and consumption demo."

# START kind
# A kind is a semantic label for an artifact, backed by exactly one physical
# type (file or directory). Declare it once at the top level; a producer then
# names the kind in place of the bare physical type.
@artifact "csvfile:file" "A tabulated result in CSV format."

@command "tabulate" "Write a data table as a csvfile artifact."
@with_output_artifact "table:csvfile" "The data table (CSV)." --result
@with_table
tabulate() {
    # knit_artifact_dir is the artifacts/ root: write into it, then bind.
    local out
    out="$(knit_artifact_dir)"
    mkdir -p "${out}"
    printf 'i,i2\n1,1\n2,4\n3,9\n' > "${out}/table.csv"
    knit_artifact "table" "table.csv"          # recorded with kind=csvfile
    printf 'wrote %s\n' "${out}/table.csv"
}
@done
# END kind

# START consume
# A consumer requires an artifact of a given kind. The parameter value is the
# artifacts-relative path of a recorded artifact; Knit resolves it, refuses a
# missing artifact or a kind mismatch, and --- with --verify-checksum ---
# re-hashes the bytes and refuses a table that changed since it was produced.
@command "summarize" "Consume a csvfile artifact and count its data rows."
@with_input_artifact "table:csvfile" "Artifacts-relative path of the CSV to read." --verify-checksum
@with_output "rows:integer" "0" "Number of data rows in the consumed table." --result
@with_table
summarize() {
    # Resolve the recorded artifacts-relative path to the on-disk file.
    local csv rows
    csv="$(knit_input_artifact_path "$(knit_get_parameter table "$@")")"
    rows=$(( $(wc -l < "${csv}") - 1 ))       # one header line; the rest are data
    knit_output "rows" "${rows}"
    printf 'summarize: %s data rows\n' "${rows}"
}
@done
# END consume

# A bare-file producer, kept out of the guide regions above. The check driver
# uses it to prove the consumer is kind-strict: a plain "file" artifact is not a
# "csvfile", so summarize refuses it.
@command "note" "Write a plain-text note as a bare file artifact."
@with_output_artifact "memo:file" "A plain-text note (the bare file kind)."
@with_table
note() {
    local out
    out="$(knit_artifact_dir)"
    mkdir -p "${out}"
    printf 'a plain note\n' > "${out}/note.txt"
    knit_artifact "memo" "note.txt"
}
@done

knit "$@"
