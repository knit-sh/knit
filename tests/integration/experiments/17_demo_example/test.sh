#!/usr/bin/env bash
# Integration test 17_demo_example.
#
# Runs the shipped julia example (examples/julia/exp.sh — the demo, a symlink to
# the docs' complete Part II experiment, docs/source/_code/julia_full2.sh) end to
# end against a real scheduler + MPI, exactly as a user would, to prove the
# flagship example works:
#
#   bootstrap -> fetch julia_code -> setup juliaenv -> submit julia --wait
#             -> aggregate -> report
#
# The example builds and launches the real julia-fractal MPI program. To keep the
# run feasible in the test clusters, a machine profile hands Spack the system
# CMake and the system MPI as non-buildable externals (as a real HPC site would);
# libpng (and its zlib) are the only specs Spack builds from source. The example
# script itself is used UNCHANGED.
#
# This also exercises the bare `source knit.sh` form the example uses: the
# experiment is copied next to knit.sh in the work directory, and the submit and
# run re-entry paths re-source it from there while the bodies run in the job /
# rank directories.
#
# Coupled to examples/julia/exp.sh (docs/source/_code/julia_full2.sh): changes to
# that script (its commands, parameters, recorded columns, or the julia-fractal
# build) may require updating this test.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/17_demo_example/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/17-demo-example-XXXXXX)
trap 'chmod -R u+w "${WORKDIR}" 2>/dev/null; rm -rf "${WORKDIR}"' EXIT

# The example uses a bare `source knit.sh`, so knit.sh must sit next to the
# script. examples/julia/exp.sh is a symlink into docs/; `cp -L` follows it and
# copies the resolved script content.
cp -L /shared/knit/examples/julia/exp.sh "${WORKDIR}/exp.sh"
cp    /shared/knit/knit.sh               "${WORKDIR}/knit.sh"
chmod +x "${WORKDIR}/exp.sh"
cd "${WORKDIR}"

# --------------------------------------------------------------------------
# Machine profile: adopt the system CMake and MPI as non-buildable Spack
# externals so the juliaenv setup does not compile them from source. Detect
# their prefixes/versions from the login node; libpng is left to Spack.
# --------------------------------------------------------------------------
CMAKE_BIN=$(command -v cmake) || fail "no system cmake on the login node"
CMAKE_PREFIX=${CMAKE_BIN%/bin/cmake}
[[ "${CMAKE_PREFIX}" != "${CMAKE_BIN}" ]] || fail "cmake not under a bin/ prefix: ${CMAKE_BIN}"
CMAKE_VER=$(cmake --version | sed -n '1s/.*version \([0-9][0-9.]*\).*/\1/p')
[[ -n "${CMAKE_VER}" ]] || fail "could not parse the cmake version"

# Pick the system MPI to adopt as a non-buildable Spack external.
if command -v sbatch >/dev/null 2>&1; then
    MPI_NAME=openmpi
elif command -v qsub >/dev/null 2>&1; then
    MPI_NAME=mpich
elif command -v flux >/dev/null 2>&1; then
    MPI_NAME=openmpi
else
    fail "no supported scheduler (sbatch/qsub/flux) found on the login node"
fi

# Resolve the MPI prefix and version. Slurm and PBS keep the system MPI on PATH.
# Flux keeps the packaged OpenMPI behind an Lmod module: probe it in a SUBSHELL
# so loading that module never puts mpirun on the script's PATH. bootstrap (below)
# must detect the flux launcher, not OpenMPI's mpirun — an MPI-native launcher
# wins the auto-detection, and mpirun would then try to start the render over
# ssh, which this single-user Flux image has no sshd for.
_probe_mpi() {   # prints: <prefix> <version>
    local mpicc ver
    mpicc=$(command -v mpicc) || return 1
    [[ "${mpicc%/bin/mpicc}" != "${mpicc}" ]] || return 1
    if [[ "${MPI_NAME}" == "openmpi" ]]; then
        ver=$(ompi_info --version 2>/dev/null | sed -n '1s/.*v\([0-9][0-9.]*\).*/\1/p')
    else
        ver=$(mpichversion 2>/dev/null | sed -n 's/.*Version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p')
    fi
    [[ -n "${ver}" ]] || return 1
    printf '%s %s\n' "${mpicc%/bin/mpicc}" "${ver}"
}
if command -v flux >/dev/null 2>&1; then
    # `module` is defined in profile.d, which a bare `bash test.sh` does not
    # source; source the module init (as the flux profile does). set +u guards
    # the module scripts' unbound-variable references. The module env stays in
    # the subshell, so the parent's PATH is unchanged for bootstrap.
    read -r MPI_PREFIX MPI_VER < <(
        set +u
        source /etc/profile.d/modules.sh 2>/dev/null || true
        module load openmpi 2>/dev/null || true
        _probe_mpi
    ) || true
else
    read -r MPI_PREFIX MPI_VER < <(_probe_mpi) || true
fi
[[ -n "${MPI_PREFIX:-}" ]] || fail "no system mpicc on the login node"
[[ -n "${MPI_VER:-}"    ]] || fail "could not parse the ${MPI_NAME} version"

cat >"${WORKDIR}/profile.json" <<JSON
{
    "description": "Demo externals: system CMake and MPI as non-buildable Spack externals.",
    "spack": {
        "packages": {
            "cmake": {
                "externals": [
                    { "spec": "cmake@${CMAKE_VER}", "prefix": "${CMAKE_PREFIX}" }
                ],
                "buildable": false
            },
            "${MPI_NAME}": {
                "externals": [
                    { "spec": "${MPI_NAME}@${MPI_VER}", "prefix": "${MPI_PREFIX}" }
                ],
                "buildable": false
            }
        }
    }
}
JSON

# --------------------------------------------------------------------------
# 1. bootstrap — provisions sqlite/jq, builds knit-cypher-to-sql (for the
#    `aggregate` graph query), and auto-provisions Spack (the juliaenv setup
#    declares Spack specs).
# --------------------------------------------------------------------------
./exp.sh bootstrap --project "integration-test-17" --profile "${WORKDIR}/profile.json"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

check_grep "\"cmake\":" ".knit/spack-config.json" "profile externals rendered (cmake)"
check_grep "\"${MPI_NAME}\":" ".knit/spack-config.json" "profile externals rendered (${MPI_NAME})"

# --------------------------------------------------------------------------
# 2. fetch julia_src — clone the julia-fractal source as a git resource (made
#    read-only and recorded for provenance) before the setup builds it.
# --------------------------------------------------------------------------
./exp.sh fetch --name julia_src -- julia_code
check_dir "resources/julia_src" "fetch materialized the julia_code resource"
check_file "resources/julia_src/CMakeLists.txt" "fetched source has CMakeLists.txt"

# --------------------------------------------------------------------------
# 3. setup juliaenv — Spack env (cmake+mpi external, libpng built), then CMake
#    build/install of the fetched julia-fractal source into the setup prefix.
# --------------------------------------------------------------------------
./exp.sh setup --name juliaenv -- juliaenv --src julia_src
check_file "setups/juliaenv/.activate.sh" "setup produced .activate.sh"
check_exec "setups/juliaenv/bin/julia-fractal" "setup built the julia-fractal binary"

# --------------------------------------------------------------------------
# 4. submit julia --wait — the job body calls `knit run` to fan the render app
#    out across the 2-node allocation (one rank per node); rank 0 writes the PNG
#    and records the metric.
# --------------------------------------------------------------------------
job_uuid=$(./exp.sh submit --setup juliaenv --nodes 2 --wait \
    -- julia --colormap fire)

job_dir="${WORKDIR}/jobs/${job_uuid}"
check_dir "${job_dir}" "julia job directory created"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${job_uuid}';" \
    "completed" \
    "julia job advanced to completed after --wait"

# The PNG rank 0 wrote, with a valid 8-byte PNG signature.
png="${job_dir}/fractal.png"
check_file "${png}" "render produced fractal.png"
sig=$(head -c8 "${png}" 2>/dev/null | od -An -tx1 | tr -d ' \n')
check_eq "${sig}" "89504e470d0a1a0a" "fractal.png has a valid PNG signature"

# --------------------------------------------------------------------------
# 5. Recording — rank-0 gating means exactly one `render` app row, carrying the
#    computed metric (inside > 0) and the image path; the runs row records the
#    render app and the resolved proc count (one rank per node across 2 nodes).
# --------------------------------------------------------------------------
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM render;" "1" \
    "exactly one render app row recorded (rank-0 gating)"

inside=$(${__ASSERT_SQLITE3} .knit/knit.db "SELECT inside FROM render;")
[[ "${inside}" =~ ^[0-9]+$ ]] || fail "render.inside is not numeric: \"${inside}\""
[[ "${inside}" -gt 0 ]] && __assert_pass "render row records inside=${inside} (> 0)" \
    || fail "render.inside must be > 0 (got ${inside})"

check_sqlite ".knit/knit.db" "SELECT image FROM render;" "${png}" \
    "render row records the produced image path"
check_sqlite ".knit/knit.db" "SELECT app, procs FROM runs;" "render|2" \
    "runs row records the render app and resolved proc count"

# --------------------------------------------------------------------------
# 6. aggregate + report — the fan-in and read-back surface. `aggregate` builds a
#    CSV straight from the provenance graph (a Cypher query) and records it as a
#    result artifact of kind insidecsv; `report` consumes that artifact
#    (checksum-verified) and names the peak inside metric.
# --------------------------------------------------------------------------
./exp.sh aggregate | tee "${WORKDIR}/aggregate.out"
check_grep "inside.csv" "${WORKDIR}/aggregate.out" "aggregate wrote the inside.csv table"
check_sqlite ".knit/knit.db" \
    "SELECT path FROM artifacts WHERE kind='insidecsv';" "inside.csv" \
    "aggregate recorded the inside.csv artifact (kind insidecsv)"
check_file "artifacts/inside.csv" "aggregate produced artifacts/inside.csv"
check_grep "${inside}" "artifacts/inside.csv" "the CSV contains the render's inside metric"

# report consumes the artifact by its artifacts-relative path and records the peak.
./exp.sh report --table inside.csv | tee "${WORKDIR}/report.out"
check_grep "peak inside metric: ${inside}" "${WORKDIR}/report.out" \
    "report named the peak inside metric from the single render"
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM report;" "1" \
    "report recorded its own row"

# The read-back added rows to aggregate/report, but no new render app row: the
# render count is still exactly one.
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM render;" "1" \
    "aggregate/report added no render row (render count unchanged)"

assert_summary
