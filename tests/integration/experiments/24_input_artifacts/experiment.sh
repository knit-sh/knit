#!/usr/bin/env bash
# Integration test experiment 24_input_artifacts.
#
# Exercises kinded artifacts and the consuming half of an artifact's lineage end
# to end, against a real bootstrap:
#
#   - "csvfile" is a semantic artifact KIND (declared with knit_register_artifact)
#     backed by the physical "file" type.
#
#   - Producer "produce" writes two artifacts: "table" carries the "csvfile" kind
#     and "note" carries the bare builtin "file" kind. Each is one row in the
#     framework-owned "artifacts" table (its kind recorded in the new "kind"
#     column) and a "produced" edge from the producer's row.
#
#   - Consumer "consume" declares knit_with_input_artifact "table:csvfile" with
#     --verify-checksum. It requires a recorded artifact of kind "csvfile",
#     resolves the path to the on-disk file with knit_input_artifact_path, reads
#     it, and records a row plus a "used_by" edge from the artifact to itself —
#     completing produce --produced--> table --used_by--> consume.
#
# The consumer is deliberately kind-strict: pointing it at the "note" artifact (a
# bare "file", not a "csvfile") is fatal, and with --verify-checksum a content
# change to the table since it was produced is fatal too. The companion test.sh
# drives both the happy path and those two refusals.
#
# Plain recorded commands (no scheduler) are used, so the behavior is identical on
# every backend; only bootstrap and the private sqlite/knit-graph are needed.

source knit.sh

knit_set_program_description "kinded input-artifact consume integration test experiment."

# --------------------------------------------------------------------------
# csvfile — a semantic artifact kind backed by the physical "file" type.
# --------------------------------------------------------------------------
knit_register_artifact "csvfile:file" "A tabulated result in CSV format."

# --------------------------------------------------------------------------
# Producer — writes a kinded CSV table and a bare-file note, each recorded as an
# artifacts row (with its kind) and linked by a "produced" edge.
# --------------------------------------------------------------------------
knit_register "produce" _produce "Produce a csvfile artifact and a plain file artifact."
knit_with_table
knit_with_output_artifact "table:csvfile" "The produced CSV table." --result
knit_with_output_artifact "note:file"     "A plain-text note (bare file kind)."
_produce() {
    local out
    out="$(knit_artifact_dir)"
    mkdir -p "${out}"

    printf 'run,value\n1,10\n2,20\n3,30\n' > "${out}/table.csv"
    knit_artifact "table" "table.csv"

    printf 'a plain note\n' > "${out}/note.txt"
    knit_artifact "note" "note.txt"
}
knit_done

# --------------------------------------------------------------------------
# Consumer — requires a csvfile artifact, re-verifies its checksum, counts the
# data rows, and leaves a "used_by" edge from the artifact to this command.
# --------------------------------------------------------------------------
knit_register "consume" _consume "Read a csvfile artifact and count its data rows."
knit_with_input_artifact "table:csvfile" "Artifacts-relative path of the CSV table to read." --verify-checksum
knit_with_table
knit_with_output "rows:integer" "0" "Number of data rows read." --result
_consume() {
    local csv
    csv="$(knit_input_artifact_path "$(knit_get_parameter table "$@")")"

    # The CSV has a one-line header; the remaining lines are the data rows.
    local rows
    rows=$(( $(wc -l < "${csv}") - 1 ))
    knit_output "rows" "${rows}"
    printf 'consume: %s data row(s)\n' "${rows}"
}
knit_done

knit "$@"
