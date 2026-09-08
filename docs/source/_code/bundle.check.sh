#!/usr/bin/env bash
# Driver for bundle.sh (not shown in the documentation). Bootstraps the
# experiment on the local backend, stages the files knit_bundle_requires names,
# runs the crunch job to produce an artifact, then exercises knit bundle and
# knit export ro-crate:
#
#   * `knit bundle` writes a .tar.gz that unpacks to a self-contained tree ---
#     the script, knit.sh, the pruned .knit/knit.db, the job log, the artifact,
#     and the required side files (a plain file and a glob match);
#   * `knit bundle --dry-run --list` prints the planned paths without writing;
#   * `knit bundle --ro-crate` embeds ro-crate-metadata.json at the archive root;
#   * `knit export ro-crate --output -` prints the manifest alone on stdout.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

# @fn in_archive()
# Echo "yes" if a tar.gz archive holds the given member path, "no" otherwise.
# The listing is captured before grepping so a `grep -q` early exit cannot
# SIGPIPE the tar under `set -o pipefail`.
in_archive() {
    local list
    list="$(tar -tzf "$1")"
    if grep -qxF "$2" <<<"${list}"; then echo yes; else echo no; fi
}

exp bootstrap --project bundle-demo --scheduler local >/dev/null

# ---- stage the required side files (relative to the script) ----------------
mkdir -p config inputs
printf 'samples: 2000\n' > config/params.yaml
printf '1 2 3\n'         > inputs/a.dat
printf '4 5 6\n'         > inputs/b.dat

# ---- produce a recorded run with an artifact ------------------------------
job_id="$(exp submit --wait -- crunch)"
check_eq "$(exp query sql --exec "SELECT state FROM jobs WHERE id='${job_id}'" 2>/dev/null)" \
    "completed" "the crunch job ran to completion"

# ---- knit bundle: a self-contained archive --------------------------------
exp bundle --output bundle.tar.gz >/dev/null
check_eq "$([[ -f bundle.tar.gz ]] && echo yes || echo no)" "yes" \
    "bundle wrote the archive"
check_eq "$(in_archive bundle.tar.gz "bundle.sh")"            "yes" "the archive holds the script"
check_eq "$(in_archive bundle.tar.gz "knit.sh")"             "yes" "the archive holds the framework"
check_eq "$(in_archive bundle.tar.gz ".knit/knit.db")"       "yes" "the archive holds the pruned database"
check_eq "$(in_archive bundle.tar.gz "config/params.yaml")"  "yes" "a required file is packed"
check_eq "$(in_archive bundle.tar.gz "inputs/a.dat")"        "yes" "a glob-matched required file is packed"
check_eq "$(in_archive bundle.tar.gz "inputs/b.dat")"        "yes" "every glob match is packed"
check_eq "$(in_archive bundle.tar.gz "jobs/${job_id}/.stdout")" "yes" "the job log is packed"
check_eq "$(in_archive bundle.tar.gz "artifacts/result.txt")"   "yes" "the artifact is packed"
# The provisioned toolchain is bulky and regenerable, so it is pruned out.
check_eq "$(tar -tzf bundle.tar.gz | grep -c '^\.knit/sqlite/' || true)" "0" \
    "the provisioned .knit toolchain is not packed"

# ---- --dry-run --list: the plan, no archive -------------------------------
out="$(exp bundle --dry-run --list 2>&1)"
check_contains "${out}" "config/params.yaml" "--list names a required file"
check_contains "${out}" "inputs/a.dat" "--list names each glob-expanded file"
check_eq "$([[ -f bundle-demo-bundle.tar.gz ]] && echo yes || echo no)" "no" \
    "--dry-run wrote no archive"

# ---- --ro-crate: the manifest embedded at the archive root ----------------
exp bundle --ro-crate --output crate.tar.gz >/dev/null
check_eq "$(in_archive crate.tar.gz "ro-crate-metadata.json")" "yes" \
    "--ro-crate embeds the manifest at the archive root"

# ---- export ro-crate: the manifest alone, on stdout -----------------------
manifest="$(exp export ro-crate --output - 2>/dev/null)"
check_contains "${manifest}" "https://w3id.org/ro/crate/1.1" \
    "export ro-crate emits an RO-Crate manifest"
check_contains "${manifest}" "wfrun/process" \
    "the manifest conforms to the Process Run Crate profile"

dc_summary
