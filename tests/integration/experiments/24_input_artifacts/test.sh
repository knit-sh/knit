#!/usr/bin/env bash
# Integration test 24_input_artifacts.
#
# Verifies kinded artifacts and the consuming half of an artifact's lineage
# against a real bootstrap:
#
#   - Producer "produce" records two artifacts rows in the framework-owned
#     "artifacts" table, each with its semantic "kind":
#       * "table" — kind "csvfile", a result;
#       * "note"  — kind "file"   (the bare builtin), not a result.
#     A "produced" edge links the producer's row to each artifact.
#
#   - Consumer "consume" declares knit_with_input_artifact "table:csvfile"
#     --verify-checksum. Pointed at the CSV table it succeeds: it reads the file,
#     records its row, and leaves a "used_by" edge from the artifact to itself,
#     completing produce --produced--> table --used_by--> consume.
#
#   - The consumer is kind-strict: pointed at the "note" artifact (a bare "file",
#     not a "csvfile") it is fatal, and with --verify-checksum a content change to
#     the table since it was produced is fatal too.
#
# Plain recorded commands (no scheduler) are used, so this runs identically on
# every backend.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/24_input_artifacts/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/24-input-artifacts-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/24_input_artifacts/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap. This also builds knit-graph, used below for the Cypher walk.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-24"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

check_exec ".knit/knit-graph/bin/knit-graph" \
    "bootstrap built the knit-graph binary"

# ==========================================================================
# Producer — two artifacts, each recorded with its kind.
# ==========================================================================
./experiment.sh produce >/dev/null

check_sqlite ".knit/knit.db" \
    "SELECT type FROM artifacts WHERE path='table.csv';" \
    "file" \
    "table artifact records its physical type"
check_sqlite ".knit/knit.db" \
    "SELECT kind FROM artifacts WHERE path='table.csv';" \
    "csvfile" \
    "table artifact records its semantic kind"
check_sqlite ".knit/knit.db" \
    "SELECT result FROM artifacts WHERE path='table.csv';" \
    "1" \
    "table artifact is marked as a result"
check_sqlite ".knit/knit.db" \
    "SELECT kind FROM artifacts WHERE path='note.txt';" \
    "file" \
    "note artifact records the bare builtin kind"

# The "produced" edge links the producer's row to the table artifact.
table_id=$(${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT id FROM artifacts WHERE path='table.csv';")
[[ -n "${table_id}" ]] || fail "no artifacts row for table.csv"
check_sqlite ".knit/knit.db" \
    "SELECT source_name FROM __provenance__
      WHERE target_id='${table_id}' AND edge_type='produced';" \
    "produce" \
    "a produced edge links produce to the table artifact"

# ==========================================================================
# Consumer, happy path — reads the csvfile artifact and records a used_by edge.
# ==========================================================================
out=$(./experiment.sh consume --table table.csv)
check_grep "3 data row(s)" <(printf '%s\n' "${out}") \
    "consumer read the csvfile artifact through knit_input_artifact_path"

check_sqlite ".knit/knit.db" "SELECT rows FROM consume;" "3" \
    "consumer recorded the data-row count"

check_sqlite ".knit/knit.db" \
    "SELECT edge_type FROM __provenance__
      WHERE source_name='artifacts' AND source_id='${table_id}'
        AND target_name='consume';" \
    "used_by" \
    "a used_by edge is recorded from the table artifact to the consumer"

# The edge's source id is the table artifact's own row id, so it joins back to
# the artifacts row, completing produce -> table -> consume.
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM __provenance__
      WHERE source_id='${table_id}' AND source_name='artifacts'
        AND target_name='consume' AND edge_type='used_by';" \
    "1" \
    "the used_by edge source id matches the table artifact's row id"

# Cypher: walk the full lineage produce -> table -> consume in one query
# (query graph writes results to stdout, logs to stderr; strip any CR).
walk=$(./experiment.sh query graph --exec \
    "MATCH (a)-[:produced]->(art:artifacts)-[:used_by]->(b)
       WHERE art.path = 'table.csv'
       RETURN b.target_name" \
    2>/dev/null | tr -d '\r')
check_eq "${walk}" "consume" \
    "Cypher walks produce -> table -> consume end to end"

# ==========================================================================
# Consumer, kind mismatch — pointed at the bare-file "note" artifact, fatal.
# ==========================================================================
if out=$(./experiment.sh consume --table note.txt 2>&1); then
    fail "consume must refuse an artifact whose kind is not csvfile"
else
    check_grep "is of kind" <(printf '%s\n' "${out}") \
        "the kind-mismatch refusal names the actual kind"
fi

# The refused consume left no used_by edge from the note artifact.
note_id=$(${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT id FROM artifacts WHERE path='note.txt';")
[[ -n "${note_id}" ]] || fail "no artifacts row for note.txt"
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM __provenance__
      WHERE source_id='${note_id}' AND target_name='consume'
        AND edge_type='used_by';" \
    "0" \
    "a kind-mismatched consume records no used_by edge"

# ==========================================================================
# Consumer, checksum mismatch — the table changed since it was produced, fatal.
# ==========================================================================
printf '4,40\n' >> "${WORKDIR}/artifacts/table.csv"
if out=$(./experiment.sh consume --table table.csv 2>&1); then
    fail "consume --verify-checksum must refuse a table changed since production"
else
    check_grep "failed checksum verification" <(printf '%s\n' "${out}") \
        "the checksum-mismatch refusal reports a verification failure"
fi

assert_summary
