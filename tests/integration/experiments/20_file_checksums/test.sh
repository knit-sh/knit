#!/usr/bin/env bash
# Integration test 20_file_checksums.
#
# Verifies the file/directory checksum feature against a real bootstrap and a
# live scheduler, over both the single-process (job) path and the app path:
#
#   - Job "process" records, in the "process" table, its file input's path and a
#     sha256: checksum, its file output's path and checksum, a directory output's
#     path and a recursive checksum, and a --no-checksum directory output's path
#     with NO companion checksum column. Each stored checksum equals the sha256
#     of the actual artifact, so the digest is the content, not a placeholder.
#
#   - App "transform" (launched by job "launch" via `knit run --procs 2`) records
#     exactly one per-app row (rank-0 gating): its input hashed once by the
#     dispatcher before launch, its output checksum filled by the dispatcher after
#     launch. Both equal the sha256 of the real files.
#
#   - A missing required app input fails before launch: the dispatcher aborts, so
#     no runs row and no per-app row are recorded and the job's stderr reports the
#     missing input.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/20_file_checksums/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/20-file-checksums-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/20_file_checksums/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# The two input files (on the shared filesystem, referenced by absolute path so
# they resolve from any compute node's job directory).
# --------------------------------------------------------------------------
JOB_INPUT="${WORKDIR}/job-input.txt"
APP_INPUT="${WORKDIR}/app-input.txt"
printf 'alpha\nbeta\ngamma\n' > "${JOB_INPUT}"
printf 'the quick brown fox\n' > "${APP_INPUT}"

# Expected stored checksum of a plain file: "sha256:" + the bare sha256 digest,
# exactly what _knit_sha256 records for a regular file.
expected_checksum() {
    printf 'sha256:%s' "$(sha256sum "$1" | awk '{print $1}')"
}

# --------------------------------------------------------------------------
# Bootstrap.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-20"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

# Wait for a --wait job's stdout/stderr to be fully flushed.
wait_for_file() {
    local file="$1" _
    for _ in $(seq 1 30); do
        [[ -s "${file}" ]] && break
        sleep 1
    done
}

# Resolve the runs-table UUID for a submitted job through the provenance graph
# (the same two-hop walk 09_run_app uses: submit -> submit:<job> -> run).
run_uuid_for_job() {
    local job_uuid="$1" job_name="$2" body_id run_id
    body_id=$(${__ASSERT_SQLITE3} .knit/knit.db \
        "SELECT target_id FROM __provenance__
         WHERE source_id='${job_uuid}' AND target_name='submit:${job_name}'
           AND edge_type='call';")
    [[ -n "${body_id}" ]] || return 0
    run_id=$(${__ASSERT_SQLITE3} .knit/knit.db \
        "SELECT target_id FROM __provenance__
         WHERE source_id='${body_id}' AND target_name='run' AND edge_type='call';")
    printf '%s' "${run_id}"
}

# ==========================================================================
# Job "process" — single-process file/directory checksums.
# ==========================================================================
proc_uuid=$(./experiment.sh submit --wait -- process --input "${JOB_INPUT}")
proc_dir="${WORKDIR}/jobs/${proc_uuid}"
check_dir "${proc_dir}" "process job directory created"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${proc_uuid}';" \
    "completed" \
    "process job advanced to completed after --wait"

# The job body's own row (distinct from the submission) joins the "process" table
# through the compute-side "submit -> submit:process" call edge.
proc_body_id=$(${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT target_id FROM __provenance__
     WHERE source_id='${proc_uuid}' AND target_name='submit:process'
       AND edge_type='call';")
[[ -n "${proc_body_id}" ]] || fail "no 'submit:process' body edge for the process job"

# ---- Input: path and content checksum recorded -----------------------------
check_sqlite ".knit/knit.db" \
    "SELECT input FROM process WHERE id='${proc_body_id}';" \
    "${JOB_INPUT}" \
    "process row records the file input's path"
check_sqlite ".knit/knit.db" \
    "SELECT input_checksum FROM process WHERE id='${proc_body_id}';" \
    "$(expected_checksum "${JOB_INPUT}")" \
    "process row records the input's sha256 (matches the file's content)"

# ---- File output: path and content checksum recorded -----------------------
check_sqlite ".knit/knit.db" \
    "SELECT result FROM process WHERE id='${proc_body_id}';" \
    "result.txt" \
    "process row records the file output's path"
check_sqlite ".knit/knit.db" \
    "SELECT result_checksum FROM process WHERE id='${proc_body_id}';" \
    "$(expected_checksum "${proc_dir}/result.txt")" \
    "process row records the output's sha256 (matches the written file)"

# ---- Directory output: recorded with a recursive sha256 --------------------
check_sqlite ".knit/knit.db" \
    "SELECT tree FROM process WHERE id='${proc_body_id}';" \
    "tree" \
    "process row records the directory output's path"
tree_sum=$(${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT tree_checksum FROM process WHERE id='${proc_body_id}';")
if [[ "${tree_sum}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    __assert_pass "process row records a recursive sha256 for the directory output"
else
    fail "directory output checksum is not a sha256: digest: \"${tree_sum}\""
fi

# ---- --no-checksum directory output: path recorded, no checksum column ------
check_sqlite ".knit/knit.db" \
    "SELECT scratch FROM process WHERE id='${proc_body_id}';" \
    "scratch" \
    "process row records the --no-checksum output's path"
if ${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT scratch_checksum FROM process;" >/dev/null 2>&1; then
    fail "a --no-checksum output must not create a checksum column"
else
    __assert_pass "the --no-checksum directory output has no checksum column"
fi

# ==========================================================================
# Job "launch" — app "transform" via knit run: dispatcher-side checksums.
# ==========================================================================
launch_uuid=$(./experiment.sh submit --wait -- launch --input "${APP_INPUT}")
launch_dir="${WORKDIR}/jobs/${launch_uuid}"
check_dir "${launch_dir}" "launch job directory created"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${launch_uuid}';" \
    "completed" \
    "launch job advanced to completed after --wait"

# Exactly one "run -> run:transform" edge: rank-0 gating means the input is
# hashed once and the per-app row recorded once, however many ranks ran.
run_uuid=$(run_uuid_for_job "${launch_uuid}" "launch")
[[ -n "${run_uuid}" ]] || fail "no 'submit:launch -> run' edge for the launch job"
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM __provenance__ WHERE source_id='${run_uuid}'
       AND target_name='run:transform' AND edge_type='call';" \
    "1" \
    "exactly one per-app row recorded (rank-0 gating: input hashed once)"

app_uuid=$(${__ASSERT_SQLITE3} .knit/knit.db \
    "SELECT target_id FROM __provenance__ WHERE source_id='${run_uuid}'
       AND target_name='run:transform' AND edge_type='call';")
[[ -n "${app_uuid}" ]] || fail "no 'run -> run:transform' edge for the launch run"

# ---- App input: hashed once by the dispatcher, recorded on the app row ------
check_sqlite ".knit/knit.db" \
    "SELECT input FROM transform WHERE id='${app_uuid}';" \
    "${APP_INPUT}" \
    "transform row records the app input's path"
check_sqlite ".knit/knit.db" \
    "SELECT input_checksum FROM transform WHERE id='${app_uuid}';" \
    "$(expected_checksum "${APP_INPUT}")" \
    "transform row records the dispatcher-computed input sha256"

# ---- App output: checksum filled by the dispatcher after launch ------------
check_sqlite ".knit/knit.db" \
    "SELECT out FROM transform WHERE id='${app_uuid}';" \
    "transform-out.txt" \
    "transform row records the app output's path (written by rank 0)"
check_sqlite ".knit/knit.db" \
    "SELECT out_checksum FROM transform WHERE id='${app_uuid}';" \
    "$(expected_checksum "${launch_dir}/transform-out.txt")" \
    "dispatcher filled the output sha256 after launch (matches the written file)"

# ==========================================================================
# Missing required app input fails before launch.
#
# The dispatcher checks input existence before any rank is launched, so a missing
# input aborts before the runs row is even recorded: the transform row count is
# unchanged and the job's stderr reports the missing input.
# ==========================================================================
before_count=$(${__ASSERT_SQLITE3} .knit/knit.db "SELECT COUNT(*) FROM transform;")
check_eq "${before_count}" "1" "one transform row recorded before the bad run"

set +e
bad_uuid=$(./experiment.sh submit --wait -- launch --input "${WORKDIR}/nope.txt")
set -e
bad_dir="${WORKDIR}/jobs/${bad_uuid}"
wait_for_file "${bad_dir}/.stderr"
check_grep "does not exist" "${bad_dir}/.stderr" \
    "the dispatcher reports the missing input"

after_count=$(${__ASSERT_SQLITE3} .knit/knit.db "SELECT COUNT(*) FROM transform;")
check_eq "${after_count}" "1" \
    "the missing input recorded no per-app row (aborted before launch)"

# No runs row was recorded for the aborted run either (aborted before the runs
# row is persisted), so the job has no "submit:launch -> run" edge.
bad_run_uuid=$(run_uuid_for_job "${bad_uuid}" "launch")
check_eq "${bad_run_uuid}" "" \
    "the aborted run recorded no runs row (failed before launch)"

assert_summary
