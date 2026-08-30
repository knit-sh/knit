#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- STEP 3: the `julia` command becomes a *job*, submitted to
# run in the background (and, on a cluster, on other machines) rather than in the
# foreground. The setup is unchanged from Step 2; only the registration of
# `julia` changes (@command -> @job) and its body now writes its
# image under the job's own working directory.
#
# Source-only: building the setup needs a live Spack, a compiler, and network
# access, and submitting needs a scheduler, none of which run in plain CI, so
# check-docs only syntax-checks this file. Behavior was validated live during
# development.

source knit.sh

@set_program_description "Render a Julia-set fractal."

# The setup is exactly the one from Step 2: it builds and installs julia-fractal.
@setup "juliaenv" "Build and install julia-fractal from source."
@with_spack_specs "cmake" "libpng"
@with_optional "ref:string" "v1.1.0" "git ref to build (tag, branch, or commit)."
_juliaenv_setup() {
    local ref
    ref="$(knit_get_parameter "ref" "$@")"

    git clone "https://github.com/knit-sh/julia-fractal-example.git" \
        "${KNIT_SETUP_PREFIX}/src"
    git -C "${KNIT_SETUP_PREFIX}/src" checkout "${ref}"

    cmake -S "${KNIT_SETUP_PREFIX}/src" -B "${KNIT_SETUP_PREFIX}/build" \
        -DCMAKE_INSTALL_PREFIX="${KNIT_SETUP_PREFIX}" \
        -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON
    cmake --build "${KNIT_SETUP_PREFIX}/build"
    cmake --install "${KNIT_SETUP_PREFIX}/build"

    export PATH="${KNIT_SETUP_PREFIX}/bin:${PATH}"
}
@done

# START job
@job "julia" "Render a Julia-set fractal as a submitted job."
@with_setup "juliaenv"
@with_optional "width:integer"    "800"    "Image width in pixels."
@with_optional "height:integer"   "600"    "Image height in pixels."
@with_optional "c-re:real"        "-0.8"   "Real part of the Julia constant c."
@with_optional "c-im:real"        "0.156"  "Imaginary part of the Julia constant c."
@with_optional "max-iter:integer" "1000"   "Maximum iterations per pixel."
@with_optional "colormap:string"  "fire"   "Palette: grayscale | fire | ocean."
julia() {
    local width height c_re c_im max_iter colormap output
    width=$(knit_get_parameter "width" "$@")
    height=$(knit_get_parameter "height" "$@")
    c_re=$(knit_get_parameter "c-re" "$@")
    c_im=$(knit_get_parameter "c-im" "$@")
    max_iter=$(knit_get_parameter "max-iter" "$@")
    colormap=$(knit_get_parameter "colormap" "$@")

    # A submitted job already runs with its working directory set to its own job
    # directory (exported as KNIT_JOB_PREFIX), so a bare relative output PNG
    # would land there too. We build an absolute path anyway: it is explicit
    # about where the image belongs and stays correct even if the body (or a
    # program it launches) changes directory first.
    local png="${KNIT_JOB_PREFIX%/}/fractal.png"
    julia-fractal "${width}" "${height}" "${c_re}" "${c_im}" "${max_iter}" \
        "${png}" "${colormap}"
}
@done
# END job

knit "$@"
