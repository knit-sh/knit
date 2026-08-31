#!/bin/bash

# A small experiment showing results and artifacts. A value output is marked as
# the headline result with --result, and file artifacts are bound three ways:
# a direct write into artifacts/, a --copy-from snapshot, and a --link-from
# reference. Kept to the local backend so it runs anywhere with bash + sqlite3.

source knit.sh

knit_set_program_description "A results and artifacts demo."

# START result
@command "measure" "Square a value and mark the result."
@with_required "x:integer" "The value to square."
@with_output   "square:integer" "0" "The squared value (the result)." --result
@with_output   "note:string"    ""  "An intermediate note (not a result)."
@with_table
measure() {
    local x
    x="$(knit_get_parameter "x" "$@")"
    knit_output "square" "$(( x * x ))"        # the headline value result
    knit_output "note"   "squared x=${x}"      # recorded, but not a result
    printf 'square=%s\n' "$(( x * x ))"
}
@done
# END result

# START declare
@command "tabulate" "Write a data table as an artifact."
@with_output   "rows:integer" "0" "How many rows were written." --result
@with_artifact "table:file" "The data table (CSV)." --result
@with_table
tabulate() {
    # knit_artifact_dir is the artifacts/ root: write into it, then declare.
    local out
    out="$(knit_artifact_dir)"
    mkdir -p "${out}"
    printf 'i,i2\n1,1\n2,4\n3,9\n' > "${out}/table.csv"
    knit_artifact "table" "table.csv"          # already inside artifacts/
    knit_output   "rows" "3"
    printf 'wrote %s\n' "${out}/table.csv"
}
@done
# END declare

# START shortcuts
@command "collect" "Bind artifacts by copy and by reference."
@with_artifact "figure:file"  "A small file, copied in for durability."
@with_artifact "dataset:file" "A large file, referenced in place." --result
@with_table
collect() {
    # --copy-from: snapshot a file into artifacts/ (missing parents are created).
    printf 'a small figure\n' > figure.svg
    knit_artifact "figure" "figure.svg" --copy-from figure.svg

    # --link-from: a big file on a fast filesystem is referenced by an
    # absolute-target symlink (no copy); its content is still checksummed.
    printf 'big dataset bytes\n' > "${PWD}/big.dat"
    knit_artifact "dataset" "dataset.dat" --link-from "${PWD}/big.dat"
    printf 'collected\n'
}
@done
# END shortcuts

knit "$@"
