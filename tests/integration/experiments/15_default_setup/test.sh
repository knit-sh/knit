#!/usr/bin/env bash
# Integration test 15_default_setup.
#
# Proves the builtin "default" setup and the setup-adoption rules, driven by a
# machine profile whose knit-marker module sets KNIT_MODULE_MARKER (the stand-in
# for "the platform environment is visible"):
#
#   - bootstrap auto-instantiates the default setup under setups/default, inlining
#     the platform activation into its .activate.sh and recording a setup row.
#   - a job declaring NEITHER directive adopts the default setup and sees the
#     marker on the compute node.
#   - the same job body with knit_without_setup runs with no setup and does NOT
#     see the marker.
#   - a plain (non-job) command with no setup declaration adopts nothing and sees
#     nothing (only jobs adopt the default implicitly).
#   - a plain command that declares knit_with_setup "default" resolves to the
#     auto-instantiated default setup and sees the marker.
#
# Both cluster images carry the knit-marker module on the default MODULEPATH and
# the matching admin profile (from experiment 12's infra).
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/15_default_setup/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

# Which cluster are we on? Reuse the baked admin profile (experiment 12); only
# the profile name differs.
if command -v sbatch >/dev/null 2>&1; then
    PROFILE="slurm"
elif command -v qsub >/dev/null 2>&1; then
    PROFILE="pbs"
else
    fail "no supported scheduler (sbatch/qsub) found on the login node"
fi

WORKDIR=$(mktemp -d /shared/runs/15-default-setup-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/15_default_setup/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
# The experiment uses a bare `source knit.sh`, so knit.sh must sit beside it.
cp /shared/knit/knit.sh "${WORKDIR}/knit.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap with the baked admin profile. This materializes .knit/platform.sh
# (module-init + `module load knit-marker <mpi>`) and auto-instantiates the
# builtin default setup carrying that activation.
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-15" --profile "${PROFILE}"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

# --------------------------------------------------------------------------
# Bootstrap materialized the default setup: an .activate.sh inlining the platform
# activation, a recorded type, and a row in the setup table.
# --------------------------------------------------------------------------
check_file "setups/default/.activate.sh" \
    "bootstrap materialized the default setup's .activate.sh"
check_grep "module load knit-marker" "setups/default/.activate.sh" \
    "default setup .activate.sh inlines the platform module load"
check_grep "^default\$" "setups/default/.setup.type" \
    "default setup directory records its type"
check_sqlite ".knit/knit.db" \
    "SELECT COUNT(*) FROM [setup:default];" \
    "1" \
    "bootstrap recorded a default setup row"

# --------------------------------------------------------------------------
# Case 1: a job that declares no setup adopts the default setup and sees the
# marker on the compute node. Its job directory lives under the unified jobs
# root (every job does, regardless of the setup it adopts).
# --------------------------------------------------------------------------
adopt_uuid=$(./experiment.sh submit --wait -- adopt)
jobdir="${WORKDIR}/jobs/${adopt_uuid}"
[[ -d "${jobdir}" ]] || fail "no job directory created for the adopting job"
for _ in $(seq 1 30); do
    [[ -s "${jobdir}/.stdout" ]] && break
    sleep 1
done
check_file "${jobdir}/.stdout" "adopt job stdout captured"
check_grep "^marker: loaded\$" "${jobdir}/.stdout" \
    "job with no setup adopts the default setup and sees the platform marker"

# --------------------------------------------------------------------------
# Case 2: the same body with knit_without_setup runs with no setup. Its job
# directory lives under the same unified jobs root, and it must NOT see the
# marker.
# --------------------------------------------------------------------------
optout_uuid=$(./experiment.sh submit --wait -- optout)
optdir="${WORKDIR}/jobs/${optout_uuid}"
[[ -d "${optdir}" ]] || fail "no job directory created for the opted-out job"
for _ in $(seq 1 30); do
    [[ -s "${optdir}/.stdout" ]] && break
    sleep 1
done
check_file "${optdir}/.stdout" "optout job stdout captured"
check_grep "^marker: <unset>\$" "${optdir}/.stdout" \
    "job with knit_without_setup runs with no setup and sees no marker"

# --------------------------------------------------------------------------
# Case 3: a plain command with no setup declaration does not adopt the default
# setup (only jobs do); it sees nothing.
# --------------------------------------------------------------------------
plain_out=$(./experiment.sh plaincmd)
check_eq "${plain_out}" "marker: <unset>" \
    "plain command does not adopt the default setup implicitly"

# --------------------------------------------------------------------------
# Case 4: a plain command that requires the default setup explicitly resolves to
# the auto-instantiated default setup and sees the marker.
# --------------------------------------------------------------------------
with_out=$(./experiment.sh withdefault)
check_eq "${with_out}" "marker: loaded" \
    "plain command with knit_with_setup \"default\" sees the platform marker"

assert_summary
