#!/usr/bin/env bash
# Driver for bootstrap.sh (not shown in the documentation). Verifies that every
# bootstrap flag mentioned in the Bootstrap stitch recipes still exists, then runs
# a single bootstrap exercising the offline-safe ones and confirms the chosen
# configuration was recorded. Kept to the local backend and offline (no --spack,
# no --profile, no --ignore-system-*, no --knit-graph-*) so it runs on any CI
# runner; those flags are validated for existence via --help only.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

# Every flag the Bootstrap recipes mention must still be accepted by bootstrap.
help="$(exp bootstrap --help 2>&1)"
for flag in \
    --project --account \
    --setup-path --job-path \
    --scheduler --default-nodefile \
    --launcher \
    --default-walltime --default-cpus-per-node \
    --spack --spack-packages \
    --ignore-system-sqlite --ignore-system-jq \
    --knit-graph-version --knit-graph-url; do
    check_contains "${help}" "${flag}" "bootstrap --help lists ${flag}"
done

# A single bootstrap exercising the offline-safe documented flags must succeed and
# freeze the chosen values into the experiment's metadata.
exp bootstrap \
    --project PROJ-1234 \
    --account my-allocation \
    --setup-path env \
    --job-path runs \
    --scheduler local \
    --launcher none \
    --default-walltime 01:30:00 \
    --default-cpus-per-node 64 >/dev/null

check_eq "$(exp metadata load --key __project__)"          "PROJ-1234" \
    "bootstrap records the project"
check_eq "$(exp metadata load --key __account__)"          "my-allocation" \
    "bootstrap records the account"
check_eq "$(exp metadata load --key __setup_path__)"       "env" \
    "bootstrap records the setup path"
check_eq "$(exp metadata load --key __job_path__)"         "runs" \
    "bootstrap records the job path"
check_eq "$(exp metadata load --key __scheduler__)"        "local" \
    "bootstrap records the scheduler"
check_eq "$(exp metadata load --key __launcher__)"         "none" \
    "bootstrap records the launcher"
check_eq "$(exp metadata load --key __default_walltime__)" "01:30:00" \
    "bootstrap records the default walltime"
check_eq "$(exp metadata load --key __node_ncpus__)"       "64" \
    "bootstrap records the default cpus-per-node"

# Re-running bootstrap updates only the option typed the second time and leaves
# every other setting alone (the "Update configuration by re-running bootstrap"
# recipe).
exp bootstrap --default-cpus-per-node 128 >/dev/null
check_eq "$(exp metadata load --key __node_ncpus__)"       "128" \
    "re-bootstrap updates the typed cpus-per-node"
check_eq "$(exp metadata load --key __project__)"          "PROJ-1234" \
    "re-bootstrap leaves the untyped project unchanged"

# A bare re-bootstrap changes nothing and reports there is nothing to update.
rerun="$(exp bootstrap 2>&1)"
check_contains "${rerun}" "nothing to update" \
    "bare re-bootstrap reports nothing to update"
check_eq "$(exp metadata load --key __node_ncpus__)"       "128" \
    "bare re-bootstrap leaves settings unchanged"

dc_summary
