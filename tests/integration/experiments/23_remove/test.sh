#!/usr/bin/env bash
# Integration test 23_remove.
#
# End-to-end exercise of `knit remove` against a real bootstrap and a live
# scheduler. A single lineage is built once:
#
#   resource "srcpkg" --used_by--> setup "env" --used_by--> job "work"
#     job "work" --call--> body --call--> a `knit run` of app "compute"
#     the job body --produced--> artifact "result.txt"
#
# It then verifies, on that lineage:
#   - --dry-run reports the erase set for each mode and changes NOTHING;
#   - remove job erases the job tree (submission, body, run, app row, artifact,
#     job directory, artifact file) but KEEPS the setup and resource, detaching
#     their used_by edges, and leaves no dangling provenance edge;
#   - a reverse lookup (SQL and `knit query graph`) finds the artifact's producer
#     no more after removal;
#   - remove artifact --path is refused while its producer is kept, and
#     --from-root widens the erase set to the whole lineage;
#   - remove setup --type / --name cascades to the job tree but keeps the
#     resource; --keep-artifacts still removes the directories but keeps and
#     lists the artifact file, while --keep-files makes no filesystem change at
#     all and lists every kept directory and artifact under "Left on disk";
#   - remove setup then really erases the setup directory;
#   - remove resource --keep-files erases the row but leaves the directory.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/23_remove/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/23-remove-XXXXXX)
# A fetched instance may be read-only; restore write before the recursive remove.
trap 'chmod -R u+w "${WORKDIR}" 2>/dev/null; rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/23_remove/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

SQL() { "${__ASSERT_SQLITE3}" .knit/knit.db "$1" 2>/dev/null; }

# Pass if <text> does NOT contain <substr>; fail otherwise.
refute_contains() {
    local text="$1" substr="$2" msg="$3"
    if [[ "${text}" != *"${substr}"* ]]; then
        __assert_pass "${msg}"
    else
        __assert_fail "${msg}"
    fi
}

# Pass if nothing exists at <path> (file, dir, or dangling symlink); fail otherwise.
check_absent() {
    local path="$1" msg="$2"
    if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        __assert_pass "${msg}"
    else
        __assert_fail "${msg}"
    fi
}

# --------------------------------------------------------------------------
# Build the local source package the "srcpkg" resource links, with the marker
# the setup reads and forwards to the app.
# --------------------------------------------------------------------------
mkdir -p "${WORKDIR}/srcpkg"
printf 'from-resource\n' > "${WORKDIR}/srcpkg/marker.txt"
export RES_LOCAL_PATH="${WORKDIR}/srcpkg"

# --------------------------------------------------------------------------
# 1. bootstrap — provisions the private sqlite (and builds knit-graph, used for
#    the Cypher reverse lookup below).
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-23"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"
check_exec ".knit/knit-graph/bin/knit-graph" \
    "bootstrap built the knit-graph binary"

# --------------------------------------------------------------------------
# 2. fetch the resource, build the setup, submit the job (the whole lineage).
# --------------------------------------------------------------------------
./experiment.sh fetch --name mysrc -- srcpkg >/dev/null
check_dir "resources/mysrc" "resource instance materialized"
resource_id=$(cat "${WORKDIR}/resources/.mysrc.resource.id")
[[ -n "${resource_id}" ]] || fail "no recorded id for the srcpkg resource"

./experiment.sh setup --name buildenv -- env --src mysrc >/dev/null
check_dir "setups/buildenv" "setup instance directory created"
check_file "setups/buildenv/marker.txt" "setup read the fetched source"
setup_id=$(cat "${WORKDIR}/setups/buildenv/.setup.id")
[[ -n "${setup_id}" ]] || fail "no recorded id for the env setup"

job_uuid=$(./experiment.sh submit --wait --setup buildenv -- work)
check_dir "jobs/${job_uuid}" "job directory created"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${job_uuid}';" "completed" \
    "job advanced to completed after --wait"

# --------------------------------------------------------------------------
# Resolve every id in the lineage before anything is erased.
# --------------------------------------------------------------------------
body_id=$(SQL "SELECT target_id FROM __provenance__
               WHERE source_id='${job_uuid}' AND target_name='submit:work'
                 AND edge_type='call';")
[[ -n "${body_id}" ]] || fail "no 'submit:work' body edge for the job"

run_uuid=$(SQL "SELECT target_id FROM __provenance__
                WHERE source_id='${body_id}' AND target_name='run'
                  AND edge_type='call';")
[[ -n "${run_uuid}" ]] || fail "no 'submit:work -> run' call edge for the job body"

app_id=$(SQL "SELECT target_id FROM __provenance__
              WHERE source_id='${run_uuid}' AND target_name='run:compute'
                AND edge_type='call';")
[[ -n "${app_id}" ]] || fail "no 'run -> run:compute' call edge for the run"

artifact_id=$(SQL "SELECT id FROM artifacts WHERE path='result.txt';")
[[ -n "${artifact_id}" ]] || fail "no artifacts row for result.txt"

# The launched app really ran: rank 0 recorded a world size of 2.
check_sqlite ".knit/knit.db" \
    "SELECT size FROM compute WHERE id='${app_id}';" "2" \
    "the compute app recorded the observed world size"

# The provider used_by edges exist before removal.
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM __provenance__
      WHERE source_id='${resource_id}' AND target_id='${setup_id}'
        AND edge_type='used_by';" "1" \
    "a used_by edge runs from the resource to the setup"
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM __provenance__
      WHERE source_id='${setup_id}' AND target_id='${job_uuid}'
        AND edge_type='used_by';" "1" \
    "a used_by edge runs from the setup to the job"

# ==========================================================================
# 3. --dry-run: report the erase set for each mode without changing anything.
# ==========================================================================

# remove job: the job tree, NOT the setup or resource.
out=$(./experiment.sh remove job --id "${job_uuid}" --dry-run)
check_grep "result.txt" <(printf '%s\n' "${out}") \
    "remove job --dry-run lists the produced artifact"
check_grep "compute"    <(printf '%s\n' "${out}") \
    "remove job --dry-run lists the launched app"
refute_contains "${out}" "(buildenv)" \
    "remove job --dry-run keeps the setup out of the erase set"
refute_contains "${out}" "(mysrc)" \
    "remove job --dry-run keeps the resource out of the erase set"

# A bare remove artifact is refused while its producer (the body) is kept.
if out=$(./experiment.sh remove artifact --path result.txt --dry-run 2>&1); then
    fail "remove artifact --path must be refused while its producer is kept"
else
    check_grep "from-root" <(printf '%s\n' "${out}") \
        "the bare-artifact refusal points at --from-root"
fi

# --from-root widens to the whole lineage (the job tree + artifact), still not
# the setup/resource (used_by edges are never walked).
out=$(./experiment.sh remove artifact --path result.txt --from-root --dry-run)
check_grep "result.txt" <(printf '%s\n' "${out}") \
    "remove artifact --from-root lists the artifact"
check_grep "work"       <(printf '%s\n' "${out}") \
    "remove artifact --from-root climbs to the producing job"
refute_contains "${out}" "(buildenv)" \
    "remove artifact --from-root keeps the setup out"

# remove setup cascades to its consumer (the whole job tree) but keeps the
# resource.
out=$(./experiment.sh remove setup --type env --dry-run)
check_grep "env (buildenv)" <(printf '%s\n' "${out}") \
    "remove setup --type lists the setup itself"
check_grep "result.txt"     <(printf '%s\n' "${out}") \
    "remove setup --type cascades to the job's artifact"
refute_contains "${out}" "(mysrc)" \
    "remove setup --type keeps the resource out"

# --keep-artifacts still removes the directories but moves the artifact entry
# into "Left on disk".
out=$(./experiment.sh remove setup --name buildenv --keep-artifacts --dry-run)
check_grep "Left on disk"  <(printf '%s\n' "${out}") \
    "remove --keep-artifacts reports a Left on disk section"
check_grep "artifact, --keep-artifacts" <(printf '%s\n' "${out}") \
    "remove --keep-artifacts marks the kept artifact entry"
check_grep "Directories and artifacts removed" <(printf '%s\n' "${out}") \
    "remove --keep-artifacts still removes the directories"

# --keep-files makes no filesystem change at all: every directory and the
# artifact land in "Left on disk", and nothing is reported as removed.
out=$(./experiment.sh remove setup --name buildenv --keep-files --dry-run)
check_grep "Left on disk"  <(printf '%s\n' "${out}") \
    "remove --keep-files reports a Left on disk section"
check_grep "artifact, --keep-files" <(printf '%s\n' "${out}") \
    "remove --keep-files marks the kept artifact entry"
check_grep "directory, --keep-files" <(printf '%s\n' "${out}") \
    "remove --keep-files lists the kept directories"
refute_contains "${out}" "Directories and artifacts removed" \
    "remove --keep-files removes nothing"

# Nothing was deleted by any dry-run.
check_sqlite ".knit/knit.db" "SELECT count(*) FROM jobs WHERE id='${job_uuid}';" \
    "1" "dry-run left the job row in place"
check_sqlite ".knit/knit.db" "SELECT count(*) FROM \"setup:env\";" "1" \
    "dry-run left the setup row in place"
check_sqlite ".knit/knit.db" "SELECT count(*) FROM artifacts WHERE path='result.txt';" \
    "1" "dry-run left the artifact row in place"
check_dir  "jobs/${job_uuid}" "dry-run left the job directory in place"
check_file "artifacts/result.txt" "dry-run left the artifact file in place"

# ==========================================================================
# 4. remove job --yes: erase the job tree, keep the setup and resource.
# ==========================================================================
./experiment.sh remove job --id "${job_uuid}" --yes >/dev/null

# The whole job tree is gone from the database.
check_sqlite ".knit/knit.db" "SELECT count(*) FROM jobs WHERE id='${job_uuid}';" \
    "0" "the job submission row is gone"
check_sqlite ".knit/knit.db" "SELECT count(*) FROM work WHERE id='${body_id}';" \
    "0" "the job body row is gone"
check_sqlite ".knit/knit.db" "SELECT count(*) FROM runs WHERE id='${run_uuid}';" \
    "0" "the run row is gone"
check_sqlite ".knit/knit.db" "SELECT count(*) FROM compute WHERE id='${app_id}';" \
    "0" "the per-app row is gone"
check_sqlite ".knit/knit.db" "SELECT count(*) FROM artifacts WHERE path='result.txt';" \
    "0" "the artifact row is gone"

# The on-disk job directory and artifact entry are gone.
check_absent "jobs/${job_uuid}"    "the job directory was removed"
check_absent "artifacts/result.txt" "the artifact entry was removed"

# The setup and resource survive, rows and directories both.
check_sqlite ".knit/knit.db" "SELECT count(*) FROM \"setup:env\" WHERE id='${setup_id}';" \
    "1" "the setup row survives remove job"
check_sqlite ".knit/knit.db" "SELECT count(*) FROM \"resource:srcpkg\" WHERE id='${resource_id}';" \
    "1" "the resource row survives remove job"
check_dir "setups/buildenv"  "the setup directory survives remove job"
check_dir "resources/mysrc"  "the resource directory survives remove job"

# The setup's used_by edge into the job is detached; the resource's edge into the
# kept setup remains.
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM __provenance__ WHERE source_id='${setup_id}' AND edge_type='used_by';" \
    "0" "the setup -> job used_by edge is detached"
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM __provenance__
      WHERE source_id='${resource_id}' AND target_id='${setup_id}' AND edge_type='used_by';" \
    "1" "the resource -> setup used_by edge is untouched"

# No provenance edge references any erased id (no dangling edges).
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM __provenance__ WHERE
        source_id IN ('${job_uuid}','${body_id}','${run_uuid}','${app_id}','${artifact_id}') OR
        target_id IN ('${job_uuid}','${body_id}','${run_uuid}','${app_id}','${artifact_id}');" \
    "0" "no dangling provenance edge references an erased id"

# ==========================================================================
# 5. Reverse lookup no longer finds the artifact's producer.
# ==========================================================================
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM artifacts a
       JOIN __provenance__ p ON p.target_id = a.id AND p.edge_type = 'produced'
      WHERE a.path = 'result.txt';" \
    "0" "SQL reverse lookup finds no producer after removal"

producer=$(./experiment.sh query graph --exec \
    "MATCH (t)-[e:produced]->(a:artifacts)
       WHERE a.path = 'result.txt'
       RETURN e.source_name" \
    2>/dev/null | tr -d '\r')
check_eq "${producer}" "" \
    "Cypher reverse lookup finds no producer after removal"

# ==========================================================================
# 6. remove setup --name --yes: really erase the surviving setup directory,
#    still keeping the resource.
# ==========================================================================
./experiment.sh remove setup --name buildenv --yes >/dev/null

check_sqlite ".knit/knit.db" "SELECT count(*) FROM \"setup:env\";" "0" \
    "the setup row is gone after remove setup"
check_absent "setups/buildenv" "the setup directory was removed"

check_sqlite ".knit/knit.db" "SELECT count(*) FROM \"resource:srcpkg\";" "1" \
    "the resource still survives remove setup"
check_dir "resources/mysrc" "the resource directory still survives remove setup"

# The resource -> setup edge is now detached (its target setup was erased).
check_sqlite ".knit/knit.db" \
    "SELECT count(*) FROM __provenance__ WHERE source_id='${resource_id}' AND edge_type='used_by';" \
    "0" "the resource -> setup used_by edge is detached after remove setup"

# ==========================================================================
# 7. remove resource --keep-files --yes: erase the row but leave every file.
#    The last surviving entity is the resource; remove it with --keep-files and
#    confirm the database row is gone while the on-disk directory stays.
# ==========================================================================
out=$(./experiment.sh remove resource --name mysrc --keep-files --yes)
check_grep "resource directory, --keep-files" <(printf '%s\n' "${out}") \
    "remove --keep-files lists the kept resource directory"
refute_contains "${out}" "Directories and artifacts removed" \
    "remove --keep-files removes nothing from disk"

check_sqlite ".knit/knit.db" "SELECT count(*) FROM \"resource:srcpkg\";" "0" \
    "remove --keep-files erased the resource row"
check_dir "resources/mysrc" \
    "remove --keep-files left the resource directory on disk"

assert_summary
