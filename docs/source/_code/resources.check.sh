#!/usr/bin/env bash
# Driver for resources.sh (not shown in the documentation). Bootstraps the
# experiment, stages a local dataset directory, fetches it as a named resource
# instance with the local backend (no network), then runs the consumer that
# declares knit_with_resource and reads the instance through knit_resource_path.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project resources-demo --scheduler local >/dev/null

# Stage a local dataset the `dataset` resource type will point at.
mkdir -p data
printf 'alpha\nbeta\ngamma\n' > data/values.txt

# Fetch a named instance of the dataset. `knit fetch` prints the instance path on
# stdout (all logging is on stderr), so it is safe to capture.
path="$(exp fetch --name sample -- dataset --path "${PWD}/data")"
check_contains "${path}" "resources/sample" "fetch prints the instance path"
check_eq "$(wc -l < resources/sample/values.txt)" "3" \
    "the instance materializes the staged dataset"

# The consumer resolves the instance by name (validated up front) and reads it.
out="$(exp summarize --data sample)"
check_contains "${out}" "3 line(s)" "the consumer reads the fetched dataset"

# It recorded its row, and the used_by edge links the resource to the consumer.
check_eq "$(exp query sql --exec "SELECT lines FROM summarize;")" "3" \
    "the consumer recorded its output row"

dc_summary
