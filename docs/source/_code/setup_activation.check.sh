#!/usr/bin/env bash
# Driver for setup_activation.sh (not shown in the documentation). Bootstraps the
# experiment, materializes the "toolenv" setup, then submits the "probe" job on
# the local backend and asserts that the job's activation COMPOSES onto its own
# environment: the setup's PATH entry is prepended (the job's own entry survives),
# the set/append variables are present, the unset variable is gone, and the
# activate line ran in declaration order.
set -uo pipefail
# shellcheck source=maint/doc-check-lib.sh
source "${KNIT_DOC_LIB}"

# A distinctive PATH entry the job must KEEP: if activation clobbered PATH instead
# of prepending, this entry would vanish from the job's recorded PATH.
export PATH="/doc/marker/bin:${PATH}"

exp bootstrap --project setup-activation >/dev/null

# Materialize a "toolenv" setup instance named "tools". This runs the setup body,
# which writes the composable lines into setups/tools/.activate.sh.
exp setup --name tools -- toolenv >/dev/null

# The recorded activation lines keep ${PATH} literal (composable), not frozen.
check_contains "$(cat setups/tools/.activate.sh)" 'export PATH=' \
    ".activate.sh records a PATH line"
check_contains "$(cat setups/tools/.activate.sh)" '${PATH}' \
    ".activate.sh keeps \${PATH} literal so it composes"

# Run the job inside that setup and wait for it to finish (local backend).
exp submit --setup tools --wait -- probe >/dev/null

# @fn out()
# Read one recorded output column of the single probe row.
out() {
    exp query sql --exec "SELECT \"$1\" FROM probe LIMIT 1" 2>/dev/null
}

check_eq "$(out greeting)" "hello" "env_set variable reaches the job"
check_eq "$(out banner)" "hello-from-setup" \
    "activate_line ran in order and built on the set variable"
check_contains "$(out data_path)" "setups/tools/share" \
    "env_append adds the setup's search-path entry"
check_eq "$(out legacy)" "<unset>" "env_unset removes the variable in the job"

# Composition: the job's PATH holds BOTH its own marker entry and the setup's.
job_path="$(out path)"
check_contains "${job_path}" "/doc/marker/bin" \
    "the job kept its own PATH entry (activation did not clobber it)"
check_contains "${job_path}" "setups/tools/bin" \
    "the setup prepended its own PATH entry onto the job's PATH"

# The setup is sourced once (by the jobscript), so its prepended bin appears
# exactly once — not doubled by a second activation.
bin_count=$(printf '%s' "${job_path}" | tr ':' '\n' | grep -cE '/setups/tools/bin$' || true)
check_eq "${bin_count}" "1" "the setup's bin is prepended exactly once (no double-source)"

dc_summary
