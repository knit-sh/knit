#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- STEP 4: MPI enters the *setup*. The setup now asks Spack
# for an `mpi` provider as well, so CMake detects MPI and builds the parallel
# binary, and the setup declares `@provides_launcher` so the Spack-built MPI
# can act as the launcher on a machine that has none of its own. The `julia` job
# is unchanged from Step 3 --- it still runs the binary directly (a single rank);
# launching it across ranks is Step 5.
#
# Source-only: building the setup needs a live Spack, a compiler, an MPI, and
# network access, none of which run in plain CI, so check-docs only syntax-checks
# this file. Behavior was validated live during development.

source knit.sh

@set_program_description "Render a Julia-set fractal."

# START setup
@setup "juliaenv" "Build and install julia-fractal with MPI."
@with_spack_specs "cmake" "libpng" "mpi"
@provides_launcher
@with_optional "ref:string" "v1.1.0" "git ref to build (tag, branch, or commit)."
_juliaenv_setup() {
    # cmake, libpng, and an MPI (mpicc/mpicxx, mpirun/mpiexec) are on PATH here,
    # provided by the Spack environment declared above. Everything we install goes
    # under KNIT_SETUP_PREFIX.
    local ref
    ref="$(knit_get_parameter "ref" "$@")"

    git clone "https://github.com/knit-sh/julia-fractal-example.git" \
        "${KNIT_SETUP_PREFIX}/src"
    git -C "${KNIT_SETUP_PREFIX}/src" checkout "${ref}"

    # CMake runs find_package(MPI). Because an MPI is now in the environment, it
    # finds one and builds the parallel binary; with no MPI (Step 2) it built the
    # serial one. The experiment code is identical --- only the environment changed.
    cmake -S "${KNIT_SETUP_PREFIX}/src" -B "${KNIT_SETUP_PREFIX}/build" \
        -DCMAKE_INSTALL_PREFIX="${KNIT_SETUP_PREFIX}" \
        -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON
    cmake --build "${KNIT_SETUP_PREFIX}/build"
    cmake --install "${KNIT_SETUP_PREFIX}/build"

    export PATH="${KNIT_SETUP_PREFIX}/bin:${PATH}"
}
@done
# END setup

@job "julia" "Render a Julia-set fractal as a submitted job."
@with_setup "juliaenv"
@with_optional "width:integer"    "800"    "Image width in pixels."
@with_optional "height:integer"   "600"    "Image height in pixels."
@with_optional "c-re:real"        "-0.8"   "Real part of the Julia constant c."
@with_optional "c-im:real"        "0.156"  "Imaginary part of the Julia constant c."
@with_optional "max-iter:integer" "1000"   "Maximum iterations per pixel."
@with_optional "colormap:string"  "fire"   "Palette: grayscale | fire | ocean."
@with_optional "output:string"    "fractal.png" "PNG file name, written in the job directory."
julia() {
    local width height c_re c_im max_iter colormap output
    width=$(knit_get_parameter "width" "$@")
    height=$(knit_get_parameter "height" "$@")
    c_re=$(knit_get_parameter "c-re" "$@")
    c_im=$(knit_get_parameter "c-im" "$@")
    max_iter=$(knit_get_parameter "max-iter" "$@")
    colormap=$(knit_get_parameter "colormap" "$@")
    output=$(knit_get_parameter "output" "$@")

    # Unchanged from Step 3: the body still runs the binary directly, so even
    # though it is now the MPI build it runs as a single rank. Step 5 launches it
    # across ranks with `knit run`.
    local png="${KNIT_JOB_PREFIX%/}/${output}"
    julia-fractal "${width}" "${height}" "${c_re}" "${c_im}" "${max_iter}" \
        "${png}" "${colormap}"
}
@done

knit "$@"
