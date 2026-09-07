#!/usr/bin/env bash
# Integration test 26_setup_activation.
#
# Proves declarative setup activation against a real scheduler: a hand-crafted
# "toolenv" setup declares a composable environment (env_set / env_prepend /
# env_append / activate_line / env_unset), and a dependent single-node job sources
# it on the compute node. The test checks both the recorded .activate.sh and the
# environment the job actually composed:
#
#   - .activate.sh records the declarations, not a snapshot: an "export" for the
#     set variable, a PATH line that keeps ${PATH} literal (the composable form),
#     the verbatim activate line, and an "unset" for the removed variable.
#   - the job sees the set variable and the activate-line variable (which built on
#     it, proving declaration order is preserved).
#   - the appended search path carries the setup's entry.
#   - the unset variable is absent even though an earlier line set it (env_unset
#     removes a set variable).
#   - the job's PATH COMPOSES: it gains the setup's bin AND keeps its own system
#     entries (the setup prepended, it did not clobber).
#
# The job is single-node with no MPI, so it runs identically on every backend.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/26_setup_activation/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/26-setup-activation-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/26_setup_activation/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap + materialize the setup instance.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-26"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

./experiment.sh setup --name tools -- toolenv

# --------------------------------------------------------------------------
# .activate.sh records the declarations, not a snapshot.
# --------------------------------------------------------------------------
activate="setups/tools/.activate.sh"
check_file "${activate}" "setup produced .activate.sh"
check_grep "export TOOL_GREETING=" "${activate}" \
    ".activate.sh records the env_set line"
# The prepend records the composable "${PATH:+:${PATH}}" form (distinctive ':+:'),
# keeping ${PATH} literal so it composes onto the job's own PATH.
check_grep ":+:" "${activate}" \
    ".activate.sh records the composable PATH prepend (keeps \${PATH} literal)"
check_grep "from-setup" "${activate}" \
    ".activate.sh records the verbatim activate line"
check_grep "unset TOOL_LEGACY" "${activate}" \
    ".activate.sh records the env_unset line"

# --------------------------------------------------------------------------
# Submit the dependent job and block until it completes.
# --------------------------------------------------------------------------
uuid=$(./experiment.sh submit --setup tools --wait -- probe)

jobdir="${WORKDIR}/jobs/${uuid}"
[[ -d "${jobdir}" ]] || fail "no job directory created for the probe job"

# --wait blocks until completion, but guard against output-flush lag over the
# shared filesystem: wait for the stdout anchor before reading the recorded row.
for _ in $(seq 1 30); do
    [[ -s "${jobdir}/.stdout" ]] && grep -q '=== end ===' "${jobdir}/.stdout" \
        && break
    sleep 1
done
check_grep "=== end ===" "${jobdir}/.stdout" "probe job ran to completion"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${uuid}';" \
    "completed" \
    "jobs row advanced to completed after the --wait job finished"

# --------------------------------------------------------------------------
# The job composed the declared environment.
# --------------------------------------------------------------------------
check_sqlite ".knit/knit.db" "SELECT greeting FROM probe LIMIT 1;" \
    "hello" \
    "env_set variable reached the job"
check_sqlite ".knit/knit.db" "SELECT banner FROM probe LIMIT 1;" \
    "hello-from-setup" \
    "activate line ran in declaration order and built on the set variable"
check_sqlite ".knit/knit.db" "SELECT legacy FROM probe LIMIT 1;" \
    "<unset>" \
    "env_unset removed the variable a prior line had set"

data_path=$("${__ASSERT_SQLITE3}" .knit/knit.db "SELECT data_path FROM probe LIMIT 1;")
case "${data_path}" in
    */setups/tools/share*)
        __assert_pass "env_append added the setup's search-path entry" ;;
    *)
        fail "TOOL_DATA_PATH missing the setup's entry (data_path=${data_path})" ;;
esac
# The setup env is sourced once (by the jobscript), so its appended entry appears
# exactly once — not doubled by a second activation.
share_count=$(printf '%s' "${data_path}" | tr ':' '\n' | grep -cE '/setups/tools/share$' || true)
check_eq "${share_count}" "1" "env_append added the entry exactly once (no double-source)"

# --------------------------------------------------------------------------
# The job's PATH COMPOSES: the setup's bin was prepended AND the job's own
# system entries survive (activation extended the PATH, it did not clobber it).
# --------------------------------------------------------------------------
job_path=$("${__ASSERT_SQLITE3}" .knit/knit.db "SELECT path FROM probe LIMIT 1;")
case "${job_path}" in
    */setups/tools/bin:*)
        __assert_pass "the setup prepended its bin onto the job's PATH" ;;
    *)
        fail "the setup's bin is not prepended to the job's PATH (path=${job_path})" ;;
esac
case "${job_path}" in
    */usr/bin*)
        __assert_pass "the job kept its own system PATH entries (not clobbered)" ;;
    *)
        fail "the job's own PATH entries were clobbered by activation (path=${job_path})" ;;
esac
# The setup env is sourced once (by the jobscript, not again by the job's
# before-callback), so its prepended bin appears exactly once.
bin_count=$(printf '%s' "${job_path}" | tr ':' '\n' | grep -cE '/setups/tools/bin$' || true)
check_eq "${bin_count}" "1" "the setup's bin is prepended exactly once (no double-source)"

assert_summary
