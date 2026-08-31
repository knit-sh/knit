#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- STEP 2: a Spack-backed setup builds and installs
# julia-fractal (no MPI yet), and the `julia` command depends on it.
#
# Source-only: building the setup needs a live Spack, a compiler, and network
# access, none of which run in plain CI, so check-docs only syntax-checks this
# file. Behavior was validated live during development.

source knit.sh

knit_set_program_description "Render a Julia-set fractal."

# START setup
@setup "juliaenv" "Build and install julia-fractal from source."
@with_spack_specs "cmake" "libpng"
@with_optional "ref:string" "v1.1.0" "git ref to build (tag, branch, or commit)."
_juliaenv_setup() {
    # The Spack environment declared above is already built and activated here, so
    # cmake and libpng are on PATH / LD_LIBRARY_PATH. Everything we install goes
    # under KNIT_SETUP_PREFIX --- the private directory Knit created for this setup.
    local ref
    ref="$(knit_get_parameter "ref" "$@")"

    git clone "https://github.com/knit-sh/julia-fractal-example.git" \
        "${KNIT_SETUP_PREFIX}/src"
    git -C "${KNIT_SETUP_PREFIX}/src" checkout "${ref}"

    # Configure, build, and install into the setup prefix. No MPI is present in
    # the environment, so CMake builds the serial binary. RPATH_USE_LINK_PATH
    # bakes the libpng location into the binary so it also runs on a machine with
    # no system libpng.
    cmake -S "${KNIT_SETUP_PREFIX}/src" -B "${KNIT_SETUP_PREFIX}/build" \
        -DCMAKE_INSTALL_PREFIX="${KNIT_SETUP_PREFIX}" \
        -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON
    cmake --build "${KNIT_SETUP_PREFIX}/build"
    cmake --install "${KNIT_SETUP_PREFIX}/build"

    # Put the installed binary on PATH for any command that depends on this setup.
    export PATH="${KNIT_SETUP_PREFIX}/bin:${PATH}"
}
@done
# END setup

@command "julia" "Render a Julia-set fractal to a PNG."
# START depends
@with_setup "juliaenv"
# END depends
@with_optional "width:integer"    "800"    "Image width in pixels."
@with_optional "height:integer"   "600"    "Image height in pixels."
@with_optional "c-re:real"        "-0.8"   "Real part of the Julia constant c."
@with_optional "c-im:real"        "0.156"  "Imaginary part of the Julia constant c."
@with_optional "max-iter:integer" "1000"   "Maximum iterations per pixel."
@with_optional "colormap:string"  "fire"   "Palette: grayscale | fire | ocean."
@with_optional "output:string"    ""       "PNG file to write (empty = no file)."
julia() {
    local width height c_re c_im max_iter colormap output
    width=$(knit_get_parameter "width" "$@")
    height=$(knit_get_parameter "height" "$@")
    c_re=$(knit_get_parameter "c-re" "$@")
    c_im=$(knit_get_parameter "c-im" "$@")
    max_iter=$(knit_get_parameter "max-iter" "$@")
    colormap=$(knit_get_parameter "colormap" "$@")
    output=$(knit_get_parameter "output" "$@")

    # The binary takes its arguments positionally:
    #   width height c_re c_im max_iter [output] [colormap]
    julia-fractal "${width}" "${height}" "${c_re}" "${c_im}" "${max_iter}" \
        "${output}" "${colormap}"
}
@done

knit "$@"
