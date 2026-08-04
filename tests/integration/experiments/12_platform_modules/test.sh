#!/usr/bin/env bash
# Integration test 12_platform_modules.
#
# Exercises the knit <-> environment-modules (Lmod) interaction driven by a
# machine profile:
#   - bootstrap --profile <cluster> resolves the admin profile baked into the
#     image at /etc/knit/profiles/<cluster>.json
#   - it materializes .knit/platform.sh with the module-init source line and a
#     single `module load knit-marker mpiB`
#   - a setup inlines that platform activation at the top of its .activate.sh
#   - a job that requires the setup re-hydrates .activate.sh on the compute node
#     and therefore sees the module-provided variables (KNIT_MODULE_MARKER from
#     the env-only marker module, KNIT_MPI_FLAVOR from the non-system MPI module)
#
# Both cluster images carry the modules on the default Lmod MODULEPATH and the
# matching profile; only the non-system MPI differs (MPICH on Slurm, OpenMPI on
# PBS), and its module is named after the implementation.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/12_platform_modules/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

# Which cluster are we on? The profile spec and the non-system MPI differ: on
# Slurm the module is MPICH (system MPI is OpenMPI); on PBS it is OpenMPI (system
# MPI is MPICH). The module name is the implementation name, and it also sets
# KNIT_MPI_FLAVOR to that same name.
if command -v sbatch >/dev/null 2>&1; then
    PROFILE="slurm"
    MPI_MODULE="mpich"
elif command -v qsub >/dev/null 2>&1; then
    PROFILE="pbs"
    MPI_MODULE="openmpi"
else
    fail "no supported scheduler (sbatch/qsub) found on the login node"
fi

WORKDIR=$(mktemp -d /shared/runs/12-platform-modules-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cp /shared/knit/tests/integration/experiments/12_platform_modules/experiment.sh \
    "${WORKDIR}/experiment.sh"
chmod +x "${WORKDIR}/experiment.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Bootstrap with the baked admin profile. This materializes .knit/platform.sh
# (and .knit/packages.yaml only if the profile had externals — it does not).
# --------------------------------------------------------------------------
./experiment.sh bootstrap --project "integration-test-12" --profile "${PROFILE}"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

# The profile was resolved from the admin store; __profile__ records the resolved
# path (not the short spec passed to --profile).
check_sqlite ".knit/knit.db" \
    "SELECT value FROM metadata WHERE key='__profile__';" \
    "/etc/knit/profiles/${PROFILE}.json" \
    "bootstrap recorded the resolved admin profile path"

# --------------------------------------------------------------------------
# platform.sh: module-init source line + one module load of the profile modules.
# --------------------------------------------------------------------------
check_file ".knit/platform.sh" "bootstrap materialized .knit/platform.sh"
check_grep "^source /etc/profile.d/modules.sh" ".knit/platform.sh" \
    "platform.sh sources the module-init script"
check_grep "^module load knit-marker ${MPI_MODULE}" ".knit/platform.sh" \
    "platform.sh loads the profile's modules in a single command"

# --------------------------------------------------------------------------
# Run the setup; its .activate.sh must inline the platform activation at the top.
# --------------------------------------------------------------------------
./experiment.sh setup --name menv -- modenv

check_file "setups/menv/.activate.sh" "setup produced .activate.sh"
check_grep "module load knit-marker ${MPI_MODULE}" "setups/menv/.activate.sh" \
    ".activate.sh inlines the platform module load"

# --------------------------------------------------------------------------
# Submit a job that requires the setup; it re-hydrates .activate.sh (and thus
# the module environment) on the compute node.
# --------------------------------------------------------------------------
uuid=$(./experiment.sh submit --setup menv --wait -- modcheck)

jobdir=$(find "${WORKDIR}/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "${jobdir}" ]] || fail "no job directory created under jobs"
check_eq "${uuid}" "$(basename "${jobdir}")" \
    "submit prints the job UUID (the job directory name)"

# --wait blocks until completion, but guard against output-flush lag.
for _ in $(seq 1 30); do
    [[ -s "${jobdir}/.stdout" ]] && break
    sleep 1
done

check_file "${jobdir}/.stdout" "job stdout captured"
check_grep "module_marker: loaded" "${jobdir}/.stdout" \
    "job sees KNIT_MODULE_MARKER from the profile-loaded env-only module"
check_grep "mpi_flavor: ${MPI_MODULE}" "${jobdir}/.stdout" \
    "job sees KNIT_MPI_FLAVOR from the profile-loaded ${MPI_MODULE} module"
check_grep "setup_marker: modenv-built" "${jobdir}/.stdout" \
    "job inherited the setup's exported marker"

assert_summary
