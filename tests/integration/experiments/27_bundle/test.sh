#!/usr/bin/env bash
# Integration test 27_bundle.
#
# Verifies `knit bundle` and `knit export ro-crate` against a real bootstrap and
# a live scheduler:
#
#   - bootstrap -> fetch a resource -> run a job that produces an artifact and an
#     out-of-tree symlinked artifact;
#   - `knit bundle` writes an archive that unpacks into a self-contained tree ---
#     the script, knit.sh, the pruned .knit/knit.db, the job log, the required
#     side file, and the artifacts are all present, and the out-of-tree symlink
#     was DEREFERENCED to a real file carrying the target's content;
#   - a fetched resource is absent from the archive by default and present with
#     --include-resources;
#   - `knit bundle --ro-crate` embeds ro-crate-metadata.json at the archive root,
#     and `knit export ro-crate` emits the manifest alone (to a file and stdout).
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/27_bundle/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/27-bundle-XXXXXX)
# An out-of-tree file (a sibling of the experiment root, on the shared
# filesystem so a compute node can read it) that an artifact references in place.
LINK_TARGET=$(mktemp /shared/runs/27-linktgt-XXXXXX.txt)
trap 'rm -rf "${WORKDIR}" "${LINK_TARGET}"' EXIT

printf 'OUT OF TREE CONTENT\n' > "${LINK_TARGET}"

cp /shared/knit/tests/integration/experiments/27_bundle/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# The required side file and the resource's staged source, both in-tree.
mkdir -p config staged
printf 'samples=10\n' > config/params.txt
printf 'row1\nrow2\n'  > staged/data.txt

# --------------------------------------------------------------------------
# Bootstrap, fetch the resource, run the job.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-27"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

./experiment.sh fetch --name mydata -- dataset >/dev/null
check_dir "resources/mydata" "the resource was fetched into resources/"

job_id="$(./experiment.sh submit --wait -- produce --link-target "${LINK_TARGET}")"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${job_id}';" "completed" \
    "the produce job ran to completion"

if [[ -L "artifacts/linked.txt" ]]; then
    __assert_pass "the linked artifact is an out-of-tree symlink in the live tree"
else
    __assert_fail "the linked artifact is an out-of-tree symlink in the live tree"
fi

# --------------------------------------------------------------------------
# knit bundle — the default archive.
# --------------------------------------------------------------------------
./experiment.sh bundle --output bundle.tar.gz >/dev/null
check_file "bundle.tar.gz" "bundle wrote the archive"

# Capture the listing once so a `grep -q` early exit cannot SIGPIPE tar under
# `set -o pipefail`.
listing="$(tar -tzf bundle.tar.gz)"
# @fn has() — is <member> an exact path in the captured archive listing?
has() { grep -qxF "$1" <<<"${listing}"; }

check_eq "$(has 'experiment.sh'            && echo yes || echo no)" "yes" "archive holds the script"
check_eq "$(has 'knit.sh'                  && echo yes || echo no)" "yes" "archive holds the framework"
check_eq "$(has '.knit/knit.db'            && echo yes || echo no)" "yes" "archive holds the pruned database"
check_eq "$(has 'config/params.txt'        && echo yes || echo no)" "yes" "archive holds the required side file"
check_eq "$(has "jobs/${job_id}/.stdout"   && echo yes || echo no)" "yes" "archive holds the job log"
check_eq "$(has 'artifacts/result.txt'     && echo yes || echo no)" "yes" "archive holds the in-tree artifact"
check_eq "$(has 'artifacts/linked.txt'     && echo yes || echo no)" "yes" "archive holds the linked artifact"

# The provisioned toolchain is bulky and regenerable, so .knit is pruned to the DB.
if grep -q '^\.knit/sqlite/' <<<"${listing}"; then
    __assert_fail "the provisioned .knit toolchain is pruned out of the archive"
else
    __assert_pass "the provisioned .knit toolchain is pruned out of the archive"
fi

# A fetched resource is excluded by default.
if grep -q '^resources/mydata' <<<"${listing}"; then
    __assert_fail "a fetched resource is absent from the archive by default"
else
    __assert_pass "a fetched resource is absent from the archive by default"
fi

# --------------------------------------------------------------------------
# Unpack into a fresh directory: the tree is self-contained and the out-of-tree
# symlink travelled as real content.
# --------------------------------------------------------------------------
FRESH=$(mktemp -d /shared/runs/27-fresh-XXXXXX)
tar -xzf bundle.tar.gz -C "${FRESH}"
check_file "${FRESH}/experiment.sh"           "unpacked tree has the script"
check_file "${FRESH}/knit.sh"                 "unpacked tree has the framework"
check_file "${FRESH}/.knit/knit.db"           "unpacked tree has the database"
check_file "${FRESH}/jobs/${job_id}/.stdout"  "unpacked tree has the job log"
check_file "${FRESH}/artifacts/result.txt"    "unpacked tree has the in-tree artifact"
if [[ -f "${FRESH}/artifacts/linked.txt" && ! -L "${FRESH}/artifacts/linked.txt" ]]; then
    __assert_pass "the out-of-tree symlink was dereferenced to a real file"
else
    __assert_fail "the out-of-tree symlink was dereferenced to a real file"
fi
check_grep "OUT OF TREE CONTENT" "${FRESH}/artifacts/linked.txt" \
    "the dereferenced content travelled into the archive"
rm -rf "${FRESH}"

# --------------------------------------------------------------------------
# --include-resources packs the resource that is excluded by default.
# --------------------------------------------------------------------------
./experiment.sh bundle --include-resources mydata --output withres.tar.gz >/dev/null
reslist="$(tar -tzf withres.tar.gz)"
if grep -q '^resources/mydata' <<<"${reslist}"; then
    __assert_pass "the resource is packed with --include-resources"
else
    __assert_fail "the resource is packed with --include-resources"
fi

# --------------------------------------------------------------------------
# --ro-crate embeds the manifest; export ro-crate emits it alone.
# --------------------------------------------------------------------------
./experiment.sh bundle --ro-crate --output crate.tar.gz >/dev/null
cratelist="$(tar -tzf crate.tar.gz)"
if grep -qxF 'ro-crate-metadata.json' <<<"${cratelist}"; then
    __assert_pass "--ro-crate embeds the manifest at the archive root"
else
    __assert_fail "--ro-crate embeds the manifest at the archive root"
fi

./experiment.sh export ro-crate --output manifest.json >/dev/null
check_file "manifest.json" "export ro-crate wrote the manifest file"
check_grep "w3id.org/ro/crate/1.1" "manifest.json" \
    "the manifest declares the RO-Crate 1.1 context"

./experiment.sh export ro-crate --output - > stdout-manifest.json 2>/dev/null
check_grep "wfrun/process" "stdout-manifest.json" \
    "export ro-crate --output - writes the manifest to stdout"

assert_summary
