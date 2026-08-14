#!/usr/bin/env bash
# Integration test 18_resources.
#
# End-to-end exercise of the resources subsystem against a real bootstrap:
#   - bootstrap builds the private sqlite (and knit-graph);
#   - a git resource is cloned from a local repository at a tag and recorded with
#     its resolved commit SHA;
#   - a url resource is downloaded and unpacked from a local archive;
#   - re-fetching the git resource with the same source is an idempotent no-op
#     (no second row);
#   - both instances are read-only on disk;
#   - a consumer declaring `knit_with_resource` reads both through
#     `knit_resource_path`, records its row, and leaves a `used_by` provenance
#     edge from each resource to the consumer.
#
# The git repository and the dataset archive are built locally and referenced
# over file://, so the test contacts no external host yet drives the real git and
# curl backends.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/18_resources/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/18-resources-XXXXXX)
# Fetched instances are made read-only (immutable), so restore write before the
# recursive remove or rm cannot descend into them.
trap 'chmod -R u+w "${WORKDIR}" 2>/dev/null; rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/18_resources/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Build the local git repository the "srctree" resource clones. A tag pins the
# ref so the checkout is independent of the default branch name.
# --------------------------------------------------------------------------
git init --quiet "${WORKDIR}/gitsrc"
printf 'julia-fractal\n' > "${WORKDIR}/gitsrc/name.txt"
printf 'int main(void){return 0;}\n' > "${WORKDIR}/gitsrc/main.c"
git -C "${WORKDIR}/gitsrc" -c user.email=ci@knit -c user.name=ci add -A
git -C "${WORKDIR}/gitsrc" -c user.email=ci@knit -c user.name=ci \
    commit --quiet -m "initial import"
git -C "${WORKDIR}/gitsrc" tag v1
export RES_GIT_URL="file://${WORKDIR}/gitsrc"
export RES_GIT_REF="v1"

# --------------------------------------------------------------------------
# Build the local dataset archive the "dataset" resource downloads. Three
# records, so the consumer's recorded count is a known value.
# --------------------------------------------------------------------------
mkdir -p "${WORKDIR}/stage"
printf 'alpha\nbeta\ngamma\n' > "${WORKDIR}/stage/records.txt"
tar -czf "${WORKDIR}/dataset.tar.gz" -C "${WORKDIR}/stage" records.txt
export RES_URL="file://${WORKDIR}/dataset.tar.gz"

# --------------------------------------------------------------------------
# 1. bootstrap — provisions the private sqlite the resource rows are recorded in.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-18"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

# --------------------------------------------------------------------------
# 2. fetch the git resource — clones the local repo at tag v1 into
#    resources/srccode and records the resolved commit SHA.
# --------------------------------------------------------------------------
git_path=$(./experiment.sh fetch --name srccode -- srctree)
check_eq "${git_path}" "${WORKDIR}/resources/srccode" \
    "git fetch prints the instance path"
check_dir "resources/srccode" "git fetch materialized the srctree instance"
check_file "resources/srccode/name.txt" "git instance carries the cloned source"
check_grep "julia-fractal" "resources/srccode/name.txt" \
    "git instance holds the committed content"

check_sqlite ".knit/knit.db" 'SELECT name FROM "resource:srctree";' "srccode" \
    "git resource row records the instance name"
check_sqlite ".knit/knit.db" 'SELECT directory FROM "resource:srctree";' \
    "${WORKDIR}/resources/srccode" \
    "git resource row records the instance directory"

commit=$(${__ASSERT_SQLITE3} .knit/knit.db 'SELECT "commit" FROM "resource:srctree";')
if [[ "${commit}" =~ ^[0-9a-f]{40}$ ]]; then
    __assert_pass "git resource row records the resolved commit SHA (${commit})"
else
    fail "resource:srctree.commit is not a 40-hex SHA: \"${commit}\""
fi

# The git instance is immutable: creating a file inside it must fail.
if : > "resources/srccode/should-not-write" 2>/dev/null; then
    fail "git instance directory should be read-only"
else
    __assert_pass "git instance directory is read-only"
fi

# --------------------------------------------------------------------------
# 3. fetch the url resource — downloads and unpacks the local archive into
#    resources/data.
# --------------------------------------------------------------------------
url_path=$(./experiment.sh fetch --name data -- dataset --uncompress)
check_eq "${url_path}" "${WORKDIR}/resources/data" \
    "url fetch prints the instance path"
check_file "resources/data/records.txt" "url fetch unpacked the archive"
check_eq "$(wc -l < resources/data/records.txt)" "3" \
    "url instance holds the three dataset records"

check_sqlite ".knit/knit.db" 'SELECT directory FROM "resource:dataset";' \
    "${WORKDIR}/resources/data" \
    "url resource row records the instance directory"

# The url instance is immutable as well.
if : > "resources/data/should-not-write" 2>/dev/null; then
    fail "url instance directory should be read-only"
else
    __assert_pass "url instance directory is read-only"
fi

# --------------------------------------------------------------------------
# 4. idempotent re-fetch — the same name with the same source is a no-op that
#    reprints the path and records no second row.
# --------------------------------------------------------------------------
git_again=$(./experiment.sh fetch --name srccode -- srctree)
check_eq "${git_again}" "${WORKDIR}/resources/srccode" \
    "re-fetch reprints the same instance path"
check_sqlite ".knit/knit.db" 'SELECT COUNT(*) FROM "resource:srctree";' "1" \
    "re-fetch recorded no second srctree row"

# --------------------------------------------------------------------------
# 5. consume both resources — the consumer resolves each instance through
#    knit_resource_path, records its row, and leaves a used_by edge per resource.
# --------------------------------------------------------------------------
out=$(./experiment.sh combine --src srccode --data data)
check_grep "3 record(s)" <(printf '%s\n' "${out}") \
    "consumer read the fetched dataset through knit_resource_path"

check_sqlite ".knit/knit.db" "SELECT records FROM combine;" "3" \
    "consumer recorded the dataset record count"

check_sqlite ".knit/knit.db" \
    "SELECT edge_type FROM __provenance__ WHERE source_name='resource:srctree' AND target_name='combine';" \
    "used_by" \
    "used_by edge recorded from the git resource to the consumer"
check_sqlite ".knit/knit.db" \
    "SELECT edge_type FROM __provenance__ WHERE source_name='resource:dataset' AND target_name='combine';" \
    "used_by" \
    "used_by edge recorded from the url resource to the consumer"

# The used_by edge's source id is the resource instance's recorded row id (its
# .resource.id sidecar), so the edge joins back to the resource row.
src_id=$(cat "${WORKDIR}/resources/.srccode.resource.id")
check_sqlite ".knit/knit.db" \
    "SELECT source_id FROM __provenance__ WHERE source_name='resource:srctree' AND target_name='combine';" \
    "${src_id}" \
    "used_by edge source id matches the git resource's recorded row id"

assert_summary
