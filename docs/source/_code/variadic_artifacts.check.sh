#!/usr/bin/env bash
# Driver for variadic_artifacts.sh (not shown in the documentation). Bootstraps
# the experiment, fans out a "*" collection of shards, then merges them through a
# "+" input with a single glob argument, and asserts: one artifacts row plus one
# produced edge per member; the glob gathers every member; one used_by edge per
# consumed member; the full produced -> used_by lineage; a "+" input whose glob
# matches nothing is fatal; and a "*" output that binds nothing is allowed.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project variadic-artifacts >/dev/null

# shard: fan out three CSV shards (a "*" collection: three bindings of one name).
check_eq "$(exp shard --n 3)" "wrote 3 shard(s)" "shard fans out three members"
check_eq "$(exp query sql --exec \
    "SELECT count(*) FROM artifacts WHERE name='shards'" \
    2>/dev/null | tr -d '[:space:]')" "3" \
    "each binding of the * collection is its own artifacts row"

# Every member also left a produced edge from shard's invocation.
check_eq "$(exp query sql --exec \
    "SELECT count(*) FROM __provenance__
      WHERE edge_type='produced' AND source_name='shard'" \
    2>/dev/null | tr -d '[:space:]')" "3" \
    "one produced edge per fanned-out member"

# merge: one glob argument gathers the whole fan-out. Each shard has one data
# row, so three shards merge to three rows.
check_eq "$(exp merge --shards 'shard-*.csv')" "merged 3 shard(s), 3 data row(s)" \
    "the + input glob gathers every member"
check_eq "$(exp query sql --exec 'SELECT rows FROM merge' \
    2>/dev/null | tr -d '[:space:]')" "3" "merge records rows=3"

# The consume left one used_by edge per resolved member, so the fan-out is fully
# joined into the lineage shard --produced--> shard-i --used_by--> merge.
check_eq "$(exp query sql --exec \
    "SELECT count(*) FROM __provenance__
      WHERE edge_type='used_by' AND target_name='merge'" \
    2>/dev/null | tr -d '[:space:]')" "3" \
    "one used_by edge per consumed member"
check_eq "$(exp query sql --exec \
    "SELECT count(*)
       FROM artifacts a
       JOIN __provenance__ pr ON pr.target_id = a.id AND pr.edge_type = 'produced'
       JOIN __provenance__ ub ON ub.source_id = a.id AND ub.edge_type = 'used_by'
      WHERE pr.source_name = 'shard' AND ub.target_name = 'merge'" \
    2>/dev/null | tr -d '[:space:]')" "3" \
    "the lineage walk shard -> shard-i -> merge returns all three members"

# A "+" input whose glob matches nothing is fatal (one or more is required).
if exp merge --shards 'nomatch-*.csv' >/dev/null 2>&1; then
    check_eq "merged" "refused" "merge must refuse an empty + expansion"
else
    check_eq "refused" "refused" "merge refuses a + input that matched nothing"
fi

# A "*" output that binds nothing is allowed (a fan-out that produced nothing is
# not an error). It writes no files, so it never trips the write-once rule.
check_eq "$(exp shard --n 0)" "wrote 0 shard(s)" \
    "a * output that binds nothing succeeds"

dc_summary
