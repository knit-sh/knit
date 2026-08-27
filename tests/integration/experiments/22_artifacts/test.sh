#!/usr/bin/env bash
# Integration test 22_artifacts.
#
# Verifies the results-and-artifacts feature against a real bootstrap and a live
# scheduler, through the job path:
#
#   - Job "bundle" records, in the "bundle" table, only its value result:
#       * "lines" — the input's line count, a bare number (knit_with_output
#         --result). It is a column of the "bundle" table, with no companion
#         checksum column.
#
#   - Each produced artifact is one row in the framework-owned "artifacts" table
#     (id/path/name/type/checksum/result), NOT a column of the "bundle" table:
#       * "dataset" — a file artifact bound with --link-from, recorded with the
#         artifacts-relative path "dataset.csv", result=1, and a checksum equal to
#         the sha256 of the resolved target.
#       * "figure"  — a file artifact bound with --copy-from, recorded with the
#         path "figure.txt", result=0, and a checksum equal to the sha256 of the
#         copy.
#
#   - A "produced" provenance edge links the job body's row to each artifact row,
#     so the producer is recoverable from a file path by a reverse lookup — a SQL
#     join on the artifact id and a `knit query graph` Cypher walk of the edge.
#
#   - On disk under artifacts/: "dataset.csv" is an absolute-target symlink into
#     the job directory, "figure.txt" is a real (non-symlink) file, and each
#     stored checksum equals the sha256 of the entry's real content.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/22_artifacts/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/22-artifacts-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/22_artifacts/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# The input file (on the shared filesystem, referenced by absolute path so it
# resolves from the compute node's job directory).
JOB_INPUT="${WORKDIR}/job-input.txt"
printf 'alpha\nbeta\ngamma\n' > "${JOB_INPUT}"

# Expected stored checksum of a plain file: "sha256:" + the bare sha256 digest,
# exactly what _knit_sha256 records for a regular file. sha256sum follows a
# symlink, so this also gives the target's digest when passed the link path.
expected_checksum() {
    printf 'sha256:%s' "$(sha256sum "$1" | awk '{print $1}')"
}

# --------------------------------------------------------------------------
# Bootstrap. This also builds knit-graph, used below for the Cypher reverse
# lookup.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-22"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

check_exec ".knit/knit-graph/bin/knit-graph" \
    "bootstrap built the knit-graph binary"

# ==========================================================================
# Job "bundle" — a value result plus two artifacts.
# ==========================================================================
job_uuid=$(./experiment.sh submit --wait -- bundle --input "${JOB_INPUT}")
job_dir="${WORKDIR}/jobs/${job_uuid}"
check_dir "${job_dir}" "bundle job directory created"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${job_uuid}';" \
    "completed" \
    "bundle job advanced to completed after --wait"

# The job body's own row (distinct from the submission) joins the "bundle" table
# through the compute-side "submit -> submit:bundle" call edge. This body row is
# the source of every "produced" edge.
body_id=$(${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT target_id FROM __provenance__
     WHERE source_id='${job_uuid}' AND target_name='submit:bundle'
       AND edge_type='call';")
[[ -n "${body_id}" ]] || fail "no 'submit:bundle' body edge for the bundle job"

# ---- Value result: the input's line count, a bare number -------------------
check_sqlite ".knit/knit.db" \
    "SELECT lines FROM bundle WHERE id='${body_id}';" \
    "3" \
    "bundle row records the value result (input line count)"
# A value result is not a file, so it has no companion checksum column.
if ${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT lines_checksum FROM bundle;" >/dev/null 2>&1; then
    fail "a value result must not create a checksum column"
else
    __assert_pass "the value result has no checksum column"
fi

# ---- An artifact is NOT a column of the producing table ---------------------
# Under the artifacts-table model the "bundle" table has no dataset/figure (nor
# their old companion checksum) columns. A dropped-column SELECT would not fail
# (SQLite treats a double-quoted unknown identifier as a string literal), so test
# the schema directly through pragma_table_info.
bundle_cols=$(${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT name FROM pragma_table_info('bundle');")
for col in dataset dataset_checksum figure figure_checksum; do
    if printf '%s\n' "${bundle_cols}" | grep -qx "${col}"; then
        fail "the bundle table must not have an artifact column: ${col}"
    fi
done
__assert_pass "the bundle table has no artifact columns"

# ==========================================================================
# Artifact "dataset" — bound with --link-from, recorded in the artifacts table.
# ==========================================================================
dataset_link="${WORKDIR}/artifacts/dataset.csv"

check_sqlite ".knit/knit.db" \
    "SELECT name FROM artifacts WHERE path='dataset.csv';" \
    "dataset" \
    "artifacts row records the linked artifact's declared name"
check_sqlite ".knit/knit.db" \
    "SELECT type FROM artifacts WHERE path='dataset.csv';" \
    "file" \
    "artifacts row records the linked artifact's type"
check_sqlite ".knit/knit.db" \
    "SELECT result FROM artifacts WHERE path='dataset.csv';" \
    "1" \
    "artifacts row marks the linked artifact as a result"

# On disk it is an absolute-target symlink into the job directory.
if [[ -L "${dataset_link}" ]]; then
    __assert_pass "artifacts/dataset.csv is a symlink (--link-from)"
else
    fail "artifacts/dataset.csv is not a symlink"
fi
dataset_target=$(readlink "${dataset_link}")
case "${dataset_target}" in
    /*) __assert_pass "the dataset symlink has an absolute target" ;;
    *)  fail "the dataset symlink target is not absolute: \"${dataset_target}\"" ;;
esac
check_eq "${dataset_target}" "${job_dir}/dataset.csv" \
    "the dataset symlink points at the file in the job directory"

# The checksum is the sha256 of the resolved target (as if physically present).
check_sqlite ".knit/knit.db" \
    "SELECT checksum FROM artifacts WHERE path='dataset.csv';" \
    "$(expected_checksum "${dataset_link}")" \
    "artifacts row records the linked target's sha256"

# ==========================================================================
# Artifact "figure" — bound with --copy-from, recorded in the artifacts table.
# ==========================================================================
figure_file="${WORKDIR}/artifacts/figure.txt"

check_sqlite ".knit/knit.db" \
    "SELECT name FROM artifacts WHERE path='figure.txt';" \
    "figure" \
    "artifacts row records the copied artifact's declared name"
check_sqlite ".knit/knit.db" \
    "SELECT type FROM artifacts WHERE path='figure.txt';" \
    "file" \
    "artifacts row records the copied artifact's type"
check_sqlite ".knit/knit.db" \
    "SELECT result FROM artifacts WHERE path='figure.txt';" \
    "0" \
    "artifacts row does not mark the copied artifact as a result"

# On disk it is a real file, not a symlink (a self-contained snapshot).
if [[ -f "${figure_file}" && ! -L "${figure_file}" ]]; then
    __assert_pass "artifacts/figure.txt is a real file (--copy-from)"
else
    fail "artifacts/figure.txt is not a real (non-symlink) file"
fi

check_sqlite ".knit/knit.db" \
    "SELECT checksum FROM artifacts WHERE path='figure.txt';" \
    "$(expected_checksum "${figure_file}")" \
    "artifacts row records the copied file's sha256"

# ==========================================================================
# The "produced" provenance edge: the job body's row -> each artifact row.
# ==========================================================================
for path in dataset.csv figure.txt; do
    aid=$(${__ASSERT_SQLITE3} .knit/knit.db \
        "SELECT id FROM artifacts WHERE path='${path}';")
    [[ -n "${aid}" ]] || fail "no artifacts row for ${path}"
    check_sqlite ".knit/knit.db" \
        "SELECT count(*) FROM __provenance__
         WHERE source_id='${body_id}' AND source_name='submit:bundle'
           AND target_id='${aid}' AND target_name='artifacts'
           AND edge_type='produced';" \
        "1" \
        "a produced edge links the bundle body to the ${path} artifact"
done

# ==========================================================================
# Reverse lookup: recover the producer from a file path.
# ==========================================================================
# SQL: join the artifacts row to its "produced" edge on the artifact id.
check_sqlite ".knit/knit.db" \
    "SELECT p.source_id FROM artifacts a
       JOIN __provenance__ p ON p.target_id = a.id AND p.edge_type = 'produced'
      WHERE a.path = 'dataset.csv';" \
    "${body_id}" \
    "SQL reverse lookup recovers the producing invocation from a file path"

# Cypher: the same walk through `knit query graph`. The producing node needs no
# label — read the producer off the edge (query graph writes results to stdout,
# logs to stderr; strip any CR).
producer=$(./experiment.sh query graph --exec \
    "MATCH (t)-[e:produced]->(a:artifacts)
       WHERE a.path = 'figure.txt'
       RETURN e.source_name" \
    2>/dev/null | tr -d '\r')
check_eq "${producer}" "submit:bundle" \
    "Cypher reverse lookup recovers the producing command from a file path"

assert_summary
