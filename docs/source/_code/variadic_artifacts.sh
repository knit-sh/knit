#!/bin/bash

# A small experiment showing VARIADIC artifacts: a producer that fans out a
# "zero or more" (*) collection, binding the same name several times, and a
# consumer that takes a "one or more" (+) input and reads every member through a
# single glob argument with knit_input_artifact_paths. Together they are the
# discover-and-merge pattern: one command scatters many files, the next gathers
# them. Kept to the local backend so it runs anywhere with bash + sqlite3.

source knit.sh

knit_set_program_description "Variadic artifacts (fan-out and glob merge) demo."

# A semantic kind for the shards, backed by the physical file type.
@artifact "csvfile:file" "A CSV shard."

# START fanout
# A "*" (zero or more) output is a COLLECTION: the body may bind the same name
# any number of times, and each binding is its own artifacts row with its own
# "produced" edge. (Use "+" for one-or-more, which is fatal if the body binds
# nothing.) Here one run scatters `n` CSV shards under the artifacts root.
@command "shard" "Fan out a range into several CSV shards."
@with_optional "n:integer" "3" "How many shards to write."
@with_output_artifact "shards:csvfile*" "The CSV shards (zero or more)."
@with_table
shard() {
    local n out i
    n="$(knit_get_parameter "n" "$@")"
    out="$(knit_artifact_dir)"
    mkdir -p "${out}"
    for (( i = 1; i <= n; i++ )); do
        printf 'id,sq\n%d,%d\n' "${i}" "$(( i * i ))" > "${out}/shard-${i}.csv"
        knit_artifact "shards" "shard-${i}.csv"    # bind one member of the collection
    done
    printf 'wrote %s shard(s)\n' "${n}"
}
@done
# END fanout

# START glob
# A "+" (one or more) input requires at least one member. Its argument is a
# comma-separated list of artifacts-relative paths, and any element holding a
# glob metacharacter (*, ?, [) is expanded against the artifacts root --- so one
# `--shards 'shard-*.csv'` gathers the whole fan-out. knit_input_artifact_paths
# fills a bash array with the resolved on-disk paths, in order, de-duplicated.
@command "merge" "Merge every shard matched by a glob into one row count."
@with_input_artifact "shards:csvfile+" "Artifacts-relative glob of the shards to merge (one or more)."
@with_output "rows:integer" "0" "Total data rows across the merged shards." --result
@with_table
merge() {
    local -a paths=()
    knit_input_artifact_paths paths "$(knit_get_parameter "shards" "$@")"
    local total=0 p
    for p in "${paths[@]}"; do
        total=$(( total + $(wc -l < "${p}") - 1 ))     # drop each shard's header line
    done
    knit_output "rows" "${total}"
    printf 'merged %s shard(s), %s data row(s)\n' "${#paths[@]}" "${total}"
}
@done
# END glob

knit "$@"
