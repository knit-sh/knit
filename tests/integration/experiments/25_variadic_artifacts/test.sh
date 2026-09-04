#!/usr/bin/env bash
# Integration test 25_variadic_artifacts.
#
# Verifies variadic artifact collections and glob inputs against a real
# bootstrap:
#
#   - Producer "shard --n 3" fans out three csvfile artifacts under one
#     collection name. Each member is one row in the framework-owned "artifacts"
#     table and one "produced" edge from the producer's row; the collection adds
#     no column to the "shard" table.
#
#   - Consumer "merge --shards 'shard-*.csv'" gathers the whole fan-out through
#     one glob, reads every member, and leaves one "used_by" edge per member. The
#     lineage shard --produced--> member --used_by--> merge then holds for every
#     file, and one Cypher walk over the two edge kinds returns the whole set.
#
#   - A "+" input refuses an empty expansion (a glob matching nothing is fatal),
#     while a "*" input accepts it (consumer "collect" succeeds with zero
#     members).
#
# Plain recorded commands (no scheduler) are used, so this runs identically on
# every backend.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/25_variadic_artifacts/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/25-variadic-artifacts-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/25_variadic_artifacts/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap. This also builds knit-graph, used below for the Cypher walk.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-25"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

check_exec ".knit/knit-graph/bin/knit-graph" \
    "bootstrap built the knit-graph binary"

# ==========================================================================
# Producer — fan out three shards under one collection name.
# ==========================================================================
out=$(./experiment.sh shard --n 3)
check_grep "wrote 3 shard(s)" <(printf '%s\n' "${out}") \
    "producer fanned out three shards"

# One artifacts row per member, all under the same collection name.
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM artifacts WHERE name='shards';" \
    "3" \
    "each fanned-out member is one artifacts row"

# Every member records the semantic kind and is marked a result.
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM artifacts WHERE name='shards' AND kind='csvfile';" \
    "3" \
    "each member records the csvfile kind"
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM artifacts WHERE name='shards' AND result='1';" \
    "3" \
    "each member is marked as a result"

# The collection adds no column to the producer's own table: "shard" has only
# its declared parameter column, not a "shards" or "shards-checksum" column.
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM pragma_table_info('shard') WHERE name IN ('shards','shards_checksum');" \
    "0" \
    "the collection adds no column to the producer table"

# One "produced" edge per member, all from the producer command's row.
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM __provenance__
      WHERE source_name='shard' AND edge_type='produced';" \
    "3" \
    "one produced edge per fanned-out member"

# ==========================================================================
# Consumer (+) — gather the whole fan-out through one glob and merge it.
# ==========================================================================
out=$(./experiment.sh merge --shards 'shard-*.csv')
check_grep "merged 3 shard(s), 3 data row(s)" <(printf '%s\n' "${out}") \
    "the glob gathered every member of the fan-out"

check_sqlite ".knit/knit.db" "SELECT rows FROM merge;" "3" \
    "consumer recorded the merged data-row count"

# One "used_by" edge per consumed member, all to the consumer's row.
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM __provenance__
      WHERE target_name='merge' AND edge_type='used_by';" \
    "3" \
    "one used_by edge per consumed member"

# The consumer's own row stores the RAW glob it was passed, not the expansion.
check_sqlite ".knit/knit.db" "SELECT shards FROM merge;" "shard-*.csv" \
    "the consumer row stores the raw glob argument"

# ==========================================================================
# Lineage — one Cypher walk shard --produced--> member --used_by--> merge
# returns the whole set. Endpoints are left unlabeled, so only the artifact
# path is projected (query graph writes results to stdout, logs to stderr).
# ==========================================================================
walk=$(./experiment.sh query graph --exec \
    "MATCH (a)-[:produced]->(art:artifacts)-[:used_by]->(b)
       RETURN art.path" \
    2>/dev/null | tr -d '\r' | sort)
check_eq "${walk}" "$(printf 'shard-1.csv\nshard-2.csv\nshard-3.csv')" \
    "the lineage walk returns every member of the collection"

# ==========================================================================
# A "+" input refuses an empty expansion.
# ==========================================================================
if out=$(./experiment.sh merge --shards 'nomatch-*.csv' 2>&1); then
    fail "a + input must refuse a glob that resolves to nothing"
else
    check_grep "resolved to nothing" <(printf '%s\n' "${out}") \
        "the empty + expansion is fatal and reports it"
fi

# The refused merge left no extra used_by edge (still exactly three).
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM __provenance__
      WHERE target_name='merge' AND edge_type='used_by';" \
    "3" \
    "a refused merge records no used_by edge"

# ==========================================================================
# A "*" input accepts the same empty expansion.
# ==========================================================================
out=$(./experiment.sh collect --shards 'nomatch-*.csv')
check_grep "collected 0 shard(s)" <(printf '%s\n' "${out}") \
    "a * input accepts a glob that resolves to nothing"

assert_summary
