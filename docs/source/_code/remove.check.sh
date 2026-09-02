#!/usr/bin/env bash
# Driver for remove.sh (not shown in the documentation). Bootstraps the
# experiment on the local backend, builds the lineage
#
#     resource srcpkg --> setup env --> job crunch --> artifact result.txt
#
# then exercises every removal mode: a non-destructive --dry-run preview, the
# callee refusal that steers a bare artifact to --from-root, removal by
# --name / --type / --id, the whole-lineage --from-root removal, --keep-artifacts
# and --keep-files, and the used_by-detaching cascade. It asserts the report
# content, the surviving rows and edges, and the on-disk side effects after each
# step.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

# @fn sql()
# Run one read-only SQL statement and strip surrounding whitespace.
sql() {
    exp query sql --exec "$1" 2>/dev/null | tr -d '[:space:]'
}

# @fn refute_contains()
# Assert that a string does NOT contain a substring.
refute_contains() {
    if [[ "$1" != *"$2"* ]]; then
        printf '  ok   %s\n' "$3"
    else
        printf '  FAIL %s (unexpectedly found "%s")\n' "$3" "$2"
        _dc_fail=1
    fi
}

# @fn present()
# Echo "yes" if a path exists (file, dir, or symlink), "no" otherwise.
present() {
    [[ -e "$1" || -L "$1" ]] && echo yes || echo no
}

exp bootstrap --project remove-demo --scheduler local >/dev/null

# ---- build the lineage ----------------------------------------------------
mkdir -p pkg
printf 'MARKER v1\n' > pkg/marker.txt

exp fetch --name mysrc -- srcpkg >/dev/null
exp setup --name buildenv -- env --src mysrc >/dev/null
job_id="$(exp submit --wait --setup buildenv -- crunch)"

check_eq "$(sql "SELECT name FROM \"resource:srcpkg\"")" "mysrc" \
    "the resource instance recorded its name"
check_eq "$(sql "SELECT name FROM \"setup:env\"")" "buildenv" \
    "the setup instance recorded its name"
check_eq "$(sql "SELECT state FROM jobs WHERE id='${job_id}'")" "completed" \
    "the job ran to completion"
check_eq "$(sql "SELECT path FROM artifacts")" "result.txt" \
    "the job produced the artifact"
check_eq "$(sql "SELECT count(*) FROM __provenance__ WHERE edge_type='used_by'")" "2" \
    "resource-->setup and setup-->job used_by edges exist"

# ---- --dry-run previews (nothing is deleted) ------------------------------
# Removing the job cascades down to its body and its artifact, but the setup and
# resource it used are providers (their used_by edges point INTO the job) and are
# left out of the erase set.
out="$(exp remove job --id "${job_id}" --dry-run 2>&1)"
check_contains "${out}" "result.txt" "dry-run lists the job's artifact"
check_contains "${out}" "crunch"     "dry-run lists the job body"
refute_contains "${out}" "(buildenv)" "dry-run keeps the setup"
check_eq "$(sql "SELECT count(*) FROM jobs")" "1" "dry-run deleted nothing"

# Removing a provider cascades to its consumers: the setup, the job that used it,
# and that job's artifact --- but not the resource above it.
out="$(exp remove setup --type env --dry-run 2>&1)"
check_contains "${out}" "env (buildenv)" "setup dry-run names the instance"
check_contains "${out}" "crunch"         "setup dry-run cascades to the job"
refute_contains "${out}" "mysrc"         "setup dry-run keeps the resource"

# A bare artifact is refused: its producer is kept, so removing just the file
# would dangle the produced edge. The message steers the user to --from-root.
out="$(exp remove artifact --path result.txt --dry-run 2>&1 || true)"
check_contains "${out}" "from-root" "a bare artifact is refused with a --from-root hint"

# --from-root erases the whole call/produced lineage the artifact belongs to.
out="$(exp remove artifact --path result.txt --from-root --dry-run 2>&1)"
check_contains "${out}" "result.txt" "--from-root lists the artifact"
check_contains "${out}" "crunch"     "--from-root reaches the producing job"

# --keep-artifacts erases the rows and removes the directories but leaves the
# artifact files, and lists them under "Left on disk".
out="$(exp remove job --id "${job_id}" --keep-artifacts --dry-run 2>&1)"
check_contains "${out}" "Left on disk"                  "--keep-artifacts reports a Left on disk section"
check_contains "${out}" "(artifact, --keep-artifacts)"  "--keep-artifacts tags the kept artifact"

# --keep-files erases the rows only and makes no filesystem change: the job
# directory and the artifact are both listed under "Left on disk", and nothing is
# reported as removed.
out="$(exp remove job --id "${job_id}" --keep-files --dry-run 2>&1)"
check_contains "${out}" "Left on disk"                   "--keep-files reports a Left on disk section"
check_contains "${out}" "(job directory, --keep-files)"  "--keep-files lists the job directory"
check_contains "${out}" "(artifact, --keep-files)"       "--keep-files lists the artifact"
refute_contains "${out}" "Directories and artifacts removed" "--keep-files removes nothing"

# ---- real removal: remove the job -----------------------------------------
exp remove job --id "${job_id}" --yes >/dev/null
check_eq "$(sql "SELECT count(*) FROM jobs")" "0" "remove job erased the jobs row"
check_eq "$(sql "SELECT count(*) FROM artifacts")" "0" "remove job erased the artifact row"
check_eq "$(present "jobs/${job_id}")" "no" "remove job deleted the job directory"
check_eq "$(present "artifacts/result.txt")" "no" "remove job deleted the artifact file"
check_eq "$(present "setups/buildenv")" "yes" "the setup directory survives"
check_eq "$(present "resources/mysrc")" "yes" "the resource directory survives"
check_eq "$(sql "SELECT count(*) FROM __provenance__ WHERE source_name='setup:env' AND edge_type='used_by'")" \
    "0" "the setup-->job used_by edge is detached"
check_eq "$(sql "SELECT count(*) FROM __provenance__ WHERE source_name='resource:srcpkg' AND edge_type='used_by'")" \
    "1" "the resource-->setup used_by edge is untouched"
check_eq "$(sql "SELECT count(*) FROM __provenance__ WHERE source_id='${job_id}' OR target_id='${job_id}'")" \
    "0" "no dangling edge references the erased job"

# ---- real removal: remove the resource cascades to the setup --------------
exp remove resource --name mysrc --yes >/dev/null
check_eq "$(sql "SELECT count(*) FROM \"resource:srcpkg\"")" "0" \
    "remove resource erased the resource row"
check_eq "$(sql "SELECT count(*) FROM \"setup:env\"")" "0" \
    "remove resource cascaded to the setup that used it"
check_eq "$(present "resources/mysrc")" "no" "the resource directory is gone"
check_eq "$(present "setups/buildenv")" "no" "the cascaded setup directory is gone"
check_eq "$(sql "SELECT count(*) FROM __provenance__ WHERE edge_type='used_by'")" "0" \
    "both used_by edges of the erased lineage are gone"

dc_summary
