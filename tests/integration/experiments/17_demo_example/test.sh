#!/usr/bin/env bash
# Integration test 17_demo_example.
#
# Runs the shipped demo experiment (examples/demo.sh) end to end against a real
# scheduler + MPI, exactly as a user would, to prove the flagship example works:
#
#   bootstrap -> fetch julia_src -> setup juliaenv -> submit render --wait -> analyze
#
# The demo builds and launches the real julia-fractal MPI program. To keep the
# run feasible in the test clusters, a machine profile hands Spack the system
# CMake and the system MPI as non-buildable externals (as a real HPC site would);
# libpng (and its zlib) are the only specs Spack builds from source. The demo
# script itself is used UNCHANGED.
#
# This also exercises the bare `source knit.sh` form the demo now uses: the
# experiment is copied next to knit.sh in the work directory, and the submit and
# run re-entry paths re-source it from there while the bodies run in the job /
# rank directories.
#
# Coupled to examples/demo.sh: changes to that script (its commands, parameters,
# recorded columns, or the julia-fractal build) may require updating this test.
#
# Run from inside the cluster login node as hpcuser:
#   bash /shared/knit/tests/integration/experiments/17_demo_example/test.sh
# ------------------------------------------------------------------------------
set -euo pipefail

source /shared/knit/tests/integration/lib/assert.sh

WORKDIR=$(mktemp -d /shared/runs/17-demo-example-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

# The demo uses a bare `source knit.sh`, so knit.sh must sit next to the script.
cp /shared/knit/examples/demo.sh "${WORKDIR}/demo.sh"
cp /shared/knit/knit.sh          "${WORKDIR}/knit.sh"
chmod +x "${WORKDIR}/demo.sh"
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

MPICC=$(command -v mpicc) || fail "no system mpicc on the login node"
MPI_PREFIX=${MPICC%/bin/mpicc}
[[ "${MPI_PREFIX}" != "${MPICC}" ]] || fail "mpicc not under a bin/ prefix: ${MPICC}"
if command -v sbatch >/dev/null 2>&1; then
    MPI_NAME=openmpi
    MPI_VER=$(ompi_info --version 2>/dev/null | sed -n '1s/.*v\([0-9][0-9.]*\).*/\1/p')
elif command -v qsub >/dev/null 2>&1; then
    MPI_NAME=mpich
    MPI_VER=$(mpichversion 2>/dev/null | sed -n 's/.*Version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p')
else
    fail "no supported scheduler (sbatch/qsub) found on the login node"
fi
[[ -n "${MPI_VER}" ]] || fail "could not parse the ${MPI_NAME} version"

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
# 1. preflight — a command usable before bootstrap. All prerequisites are
#    present in the image, so it reports ready and exits 0.
# --------------------------------------------------------------------------
./demo.sh preflight

# --------------------------------------------------------------------------
# 2. bootstrap — provisions sqlite/jq, builds knit-graph (for `analyze`), and
#    auto-provisions Spack (the juliaenv setup declares Spack specs).
# --------------------------------------------------------------------------
./demo.sh bootstrap --project "integration-test-17" --profile "${WORKDIR}/profile.json"
export __ASSERT_SQLITE3="${WORKDIR}/.knit/sqlite/bin/sqlite3"

check_grep "\"cmake\":" ".knit/spack-config.json" "profile externals rendered (cmake)"
check_grep "\"${MPI_NAME}\":" ".knit/spack-config.json" "profile externals rendered (${MPI_NAME})"

# --------------------------------------------------------------------------
# 3. fetch julia_src — clone the julia-fractal source as a git resource (made
#    read-only and recorded for provenance) before the setup builds it.
# --------------------------------------------------------------------------
./demo.sh fetch --name julia_src -- julia_code
check_dir "resources/julia_src" "fetch materialized the julia_code resource"
check_file "resources/julia_src/CMakeLists.txt" "fetched source has CMakeLists.txt"

# --------------------------------------------------------------------------
# 4. setup juliaenv — Spack env (cmake+mpi external, libpng built), then CMake
#    build/install of the fetched julia-fractal source into the setup prefix.
# --------------------------------------------------------------------------
./demo.sh setup --name juliaenv -- juliaenv --src julia_src
check_file "setups/juliaenv/.activate.sh" "setup produced .activate.sh"
check_exec "setups/juliaenv/bin/julia-fractal" "setup built the julia-fractal binary"

# --------------------------------------------------------------------------
# 5. submit render --wait — the job body calls `knit run` to fan out julia
#    across a 2-node allocation; rank 0 writes the PNG and records the metric.
# --------------------------------------------------------------------------
render_uuid=$(./demo.sh submit --setup juliaenv --nodes 2 --wait \
    -- render --procs 4 --colormap fire)

render_dir="${WORKDIR}/jobs/${render_uuid}"
check_dir "${render_dir}" "render job directory created"
check_sqlite ".knit/knit.db" \
    "SELECT state FROM jobs WHERE id='${render_uuid}';" \
    "completed" \
    "render job advanced to completed after --wait"

# The PNG rank 0 wrote, with a valid 8-byte PNG signature.
png="${render_dir}/fractal.png"
check_file "${png}" "render produced fractal.png"
sig=$(head -c8 "${png}" 2>/dev/null | od -An -tx1 | tr -d ' \n')
check_eq "${sig}" "89504e470d0a1a0a" "fractal.png has a valid PNG signature"

# --------------------------------------------------------------------------
# 6. Recording — rank-0 gating means exactly one julia app row, carrying the
#    computed metric (inside > 0) and the image path; the runs row records the
#    app and resolved proc count.
# --------------------------------------------------------------------------
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM julia;" "1" \
    "exactly one julia app row recorded (rank-0 gating)"

inside=$(${__ASSERT_SQLITE3} .knit/knit.db "SELECT inside FROM julia;")
[[ "${inside}" =~ ^[0-9]+$ ]] || fail "julia.inside is not numeric: \"${inside}\""
[[ "${inside}" -gt 0 ]] && __assert_pass "julia row records inside=${inside} (> 0)" \
    || fail "julia.inside must be > 0 (got ${inside})"

check_sqlite ".knit/knit.db" "SELECT image FROM julia;" "${png}" \
    "julia row records the produced image path"
check_sqlite ".knit/knit.db" "SELECT app, procs FROM runs;" "julia|4" \
    "runs row records the julia app and resolved proc count"

# --------------------------------------------------------------------------
# 7. analyze — the read-only query step over the recorded rows and the
#    provenance graph. It records nothing (knit_without_provenance); assert it
#    runs and surfaces this render across the SQL and graph surfaces.
# --------------------------------------------------------------------------
./demo.sh analyze | tee "${WORKDIR}/analyze.out"
check_grep "schema (catalog)" "${WORKDIR}/analyze.out" "analyze printed the catalog section"
check_grep "fire" "${WORKDIR}/analyze.out" "analyze surfaced the render (colormap fire)"
check_grep "${png}" "${WORKDIR}/analyze.out" "analyze surfaced the produced image path"

# analyze is a pure read: it added no row to any command table of its own and no
# new provenance node. Confirm the julia row count is still exactly one.
check_sqlite ".knit/knit.db" "SELECT COUNT(*) FROM julia;" "1" \
    "analyze recorded nothing (julia row count unchanged)"

assert_summary
