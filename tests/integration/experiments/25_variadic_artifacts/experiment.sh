#!/usr/bin/env bash
# Integration test experiment 25_variadic_artifacts.
#
# Exercises variadic artifact collections and glob inputs end to end, against a
# real bootstrap:
#
#   - "csvfile" is a semantic artifact KIND backed by the physical "file" type.
#
#   - Producer "shard" declares a "*" (zero or more) output collection
#     knit_with_output_artifact "shards:csvfile*". Its body writes one CSV file
#     per member under the artifacts directory and binds the SAME collection name
#     once per member with knit_artifact. Each bound member is one row in the
#     framework-owned "artifacts" table and one "produced" edge from the
#     producer's row — the collection adds NO column to the "shard" table.
#
#   - Consumer "merge" declares a "+" (one or more) input
#     knit_with_input_artifact "shards:csvfile+". Its argument is one glob that
#     Knit expands against the artifacts root, so a single --shards 'shard-*.csv'
#     gathers the whole fan-out. The body reads every resolved member through
#     knit_input_artifact_paths and records one "used_by" edge per member —
#     completing shard --produced--> member --used_by--> merge for every file.
#
#   - Consumer "collect" declares a "*" (zero or more) input. A "*" input accepts
#     an empty expansion, so a glob that matches nothing is not an error; a "+"
#     input refuses the same empty expansion and is fatal.
#
# Plain recorded commands (no scheduler) are used, so the behavior is identical on
# every backend; only bootstrap and the private sqlite/knit-graph are needed.

source knit.sh

knit_set_program_description "variadic-artifact fan-out and glob-input integration test experiment."

# --------------------------------------------------------------------------
# csvfile — a semantic artifact kind backed by the physical "file" type.
# --------------------------------------------------------------------------
knit_register_artifact "csvfile:file" "A tabulated result in CSV format."

# --------------------------------------------------------------------------
# Producer — fans out a "*" collection: one CSV per member, each bound under the
# same collection name "shards".
# --------------------------------------------------------------------------
knit_register "shard" _shard "Fan out N csvfile artifacts into one collection."
knit_with_optional "n:integer" "3" "How many shards to write."
knit_with_output_artifact "shards:csvfile*" "The fanned-out CSV shards." --result
knit_with_table
_shard() {
    local n out i
    n=$(knit_get_parameter "n" "$@")
    out="$(knit_artifact_dir)"
    mkdir -p "${out}"

    for (( i = 1; i <= n; i++ )); do
        printf 'run,value\n%s,%s\n' "${i}" "$(( i * 10 ))" > "${out}/shard-${i}.csv"
        knit_artifact "shards" "shard-${i}.csv"
    done

    printf 'wrote %s shard(s)\n' "${n}"
}
knit_done

# --------------------------------------------------------------------------
# Consumer (+) — gathers the whole collection through one glob and merges it.
# --------------------------------------------------------------------------
knit_register "merge" _merge "Merge a glob of csvfile artifacts (one or more)."
knit_with_input_artifact "shards:csvfile+" "Glob or comma list of shards to merge."
knit_with_output "rows:integer" "0" "Total data rows across the merged shards." --result
knit_with_table
_merge() {
    local -a paths=()
    knit_input_artifact_paths paths "$(knit_get_parameter "shards" "$@")"

    # Each shard has a one-line header; the remaining line is its data row.
    local total=0 p
    for p in "${paths[@]}"; do
        total=$(( total + $(wc -l < "${p}") - 1 ))
    done

    knit_output "rows" "${total}"
    printf 'merged %s shard(s), %s data row(s)\n' "${#paths[@]}" "${total}"
}
knit_done

# --------------------------------------------------------------------------
# Consumer (*) — accepts an empty expansion, so a no-match glob is not fatal.
# --------------------------------------------------------------------------
knit_register "collect" _collect "Collect a glob of csvfile artifacts (zero or more)."
knit_with_input_artifact "shards:csvfile*" "Glob or comma list of shards to collect."
knit_with_table
_collect() {
    local -a paths=()
    knit_input_artifact_paths paths "$(knit_get_parameter "shards" "$@")"
    printf 'collected %s shard(s)\n' "${#paths[@]}"
}
knit_done

knit "$@"
