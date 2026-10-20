#!/usr/bin/env bash
# Driver for search_domain.sh (not shown in the documentation). Bootstraps the
# experiment and checks that each declared --domain is reported by
# "knit describe --space" and that the command still runs with its defaults.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

exp bootstrap --project search-domain-demo --scheduler local >/dev/null

# describe --space annotates each parameter with its declared domain.
space="$(exp describe --only train --space --no-color)"
check_contains "${space}" "range [1e-5,1.0] log" "the log-scaled real range is shown"
check_contains "${space}" "values {16,32,64,128}" "the list domain is shown"
check_contains "${space}" "range [2,12]" "the integer range is shown"
check_contains "${space}" "glob data/*.csv" "the glob domain is shown"

# The command still runs; the defaults apply when the tunables are omitted.
check_eq "$(exp train)" "lr=0.01 batch=32" "the command runs with its defaults"

dc_summary
