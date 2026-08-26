#!/usr/bin/env bash
# Integration test 22_artifacts.
#
# Verifies the results-and-artifacts feature against a real bootstrap and a live
# scheduler, through the job path:
#
#   - Job "bundle" records, in the "bundle" table:
#       * "lines"   — a value result: the input's line count, a bare number.
#       * "dataset" — a file artifact bound with --link-from, recorded as the
#         artifacts-relative path "dataset.csv" with a companion "dataset_checksum"
#         equal to the sha256 of the resolved target.
#       * "figure"  — a file artifact bound with --copy-from, recorded as
#         "figure.txt" with a "figure_checksum" equal to the sha256 of the copy.
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
# Bootstrap.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-22"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

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
# through the compute-side "submit -> submit:bundle" call edge.
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

# ==========================================================================
# Artifact "dataset" — bound with --link-from.
# ==========================================================================
dataset_link="${WORKDIR}/artifacts/dataset.csv"

# The recorded value is the artifacts-relative path, not an absolute machine path.
check_sqlite ".knit/knit.db" \
    "SELECT dataset FROM bundle WHERE id='${body_id}';" \
    "dataset.csv" \
    "bundle row records the linked artifact's artifacts-relative path"

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
    "SELECT dataset_checksum FROM bundle WHERE id='${body_id}';" \
    "$(expected_checksum "${dataset_link}")" \
    "bundle row records the linked target's sha256"

# ==========================================================================
# Artifact "figure" — bound with --copy-from.
# ==========================================================================
figure_file="${WORKDIR}/artifacts/figure.txt"

check_sqlite ".knit/knit.db" \
    "SELECT figure FROM bundle WHERE id='${body_id}';" \
    "figure.txt" \
    "bundle row records the copied artifact's artifacts-relative path"

# On disk it is a real file, not a symlink (a self-contained snapshot).
if [[ -f "${figure_file}" && ! -L "${figure_file}" ]]; then
    __assert_pass "artifacts/figure.txt is a real file (--copy-from)"
else
    fail "artifacts/figure.txt is not a real (non-symlink) file"
fi

check_sqlite ".knit/knit.db" \
    "SELECT figure_checksum FROM bundle WHERE id='${body_id}';" \
    "$(expected_checksum "${figure_file}")" \
    "bundle row records the copied file's sha256"

assert_summary
