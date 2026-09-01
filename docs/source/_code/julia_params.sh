#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- PART II, section 2 (Parameter sets): the six parameters
# the `julia` job and the `render` app share --- width, height, c-re, c-im,
# max-iter and colormap --- are declared ONCE in a `julia-params` parameter set
# and imported into both commands with @with_parameter_set. The setup (a git
# resource from section 1) and the fan-in are unchanged.
#
# Source-only: building the setup needs a live Spack, a compiler, an MPI, and
# network access, none of which run in plain CI, so check-docs only syntax-checks
# this file. Behavior was validated live during development.

source knit.sh

knit_set_program_description "Render a Julia-set fractal."

# --- Resource ---------------------------------------------------------------
# The julia-fractal source, acquired once with `knit fetch` (see section 1).
@resource "julia_code" "The julia-fractal source (github.com/knit-sh/julia-fractal-example)."
@with_git "https://github.com/knit-sh/julia-fractal-example.git" "v1.1.0"
@done

# --- Setup ------------------------------------------------------------------
# Builds and installs julia-fractal from the fetched source (see section 1).
@setup "juliaenv" "Build and install julia-fractal with MPI from fetched source."
@with_resource "src:julia_code" "Name of the fetched julia-fractal source to build."
@with_spack_specs "cmake" "libpng" "mpi"
@provides_launcher
_juliaenv_setup() {
    local src
    src="$(knit_resource_path "$(knit_get_parameter "src" "$@")")"

    cmake -S "${src}" -B "${KNIT_SETUP_PREFIX}/build" \
        -DCMAKE_INSTALL_PREFIX="${KNIT_SETUP_PREFIX}" \
        -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON
    cmake --build "${KNIT_SETUP_PREFIX}/build"
    cmake --install "${KNIT_SETUP_PREFIX}/build"

    export PATH="${KNIT_SETUP_PREFIX}/bin:${PATH}"
}
@done

# --- Parameter set ----------------------------------------------------------
# START pset
# A parameter set is a named group of parameter declarations with no command of
# its own. It is defined like a command --- @parameter_set, then any number of
# @with_required / @with_optional / @with_flag lines, then @done --- but it has
# no body function. The `julia` job and the `render` app both import it below.
@parameter_set "julia-params"
@with_optional "width:integer"    "800"    "Image width in pixels."
@with_optional "height:integer"   "600"    "Image height in pixels."
@with_optional "c-re:real"        "-0.8"   "Real part of the Julia constant c."
@with_optional "c-im:real"        "0.156"  "Imaginary part of the Julia constant c."
@with_optional "max-iter:integer" "1000"   "Maximum iterations per pixel."
@with_optional "colormap:string"  "fire"   "Palette: grayscale | fire | ocean."
@done
# END pset

# --- Job --------------------------------------------------------------------
# START job
# The job imports the shared parameters with @with_parameter_set instead of
# repeating them. It still declares its own `output` parameter, which the app
# does not share, and keeps its setup dependency.
@job "julia" "Render a Julia-set fractal as a submitted job."
@with_setup "juliaenv"
@with_parameter_set "julia-params"
@with_optional "output:string" "fractal.png" "PNG file name, written in the job directory."
julia() {
    local width height c_re c_im max_iter colormap output
    width=$(knit_get_parameter "width" "$@")
    height=$(knit_get_parameter "height" "$@")
    c_re=$(knit_get_parameter "c-re" "$@")
    c_im=$(knit_get_parameter "c-im" "$@")
    max_iter=$(knit_get_parameter "max-iter" "$@")
    colormap=$(knit_get_parameter "colormap" "$@")
    output=$(knit_get_parameter "output" "$@")

    local png="${KNIT_JOB_PREFIX%/}/${output}"

    printf 'The job is running on hosts: %s\n' \
        "$(knit_job_hostnames --separator ', ')"

    knit run --procs "$(knit_job_nodecount)" --procs-per-node 1 -- render \
        --width "${width}" --height "${height}" \
        --c-re "${c_re}" --c-im "${c_im}" --max-iter "${max_iter}" \
        --colormap "${colormap}" --output "${png}"
}
@done
# END job

# --- App --------------------------------------------------------------------
# START app
# The app imports the SAME parameter set. `output` differs from the job's ---
# here it is required (the job supplies one absolute path per run) --- so it
# stays a per-command declaration, alongside the recorded `inside` output.
@app "render" "Render one MPI-parallel Julia-set image."
@with_parameter_set "julia-params"
@with_required "output:string"           "Absolute PNG path (the job supplies one per run)."
@with_output   "inside:integer"   "0"    "Grid points inside the set (recorded by rank 0)."
_render_app() {
    local width height c_re c_im max_iter colormap output
    width=$(knit_get_parameter "width" "$@")
    height=$(knit_get_parameter "height" "$@")
    c_re=$(knit_get_parameter "c-re" "$@")
    c_im=$(knit_get_parameter "c-im" "$@")
    max_iter=$(knit_get_parameter "max-iter" "$@")
    colormap=$(knit_get_parameter "colormap" "$@")
    output=$(knit_get_parameter "output" "$@")

    local out
    out=$(julia-fractal "${width}" "${height}" "${c_re}" "${c_im}" "${max_iter}" \
        "${output}" "${colormap}")
    printf '%s\n' "${out}"

    local inside
    inside=$(sed -n 's/.*inside=\([0-9]*\).*/\1/p' <<< "${out}" | head -1)
    knit_output "inside" "${inside}"
}
@done
# END app

# --- Fan-in -----------------------------------------------------------------
# Reads back what the renders recorded (unchanged from Part I).
@command "aggregate" \
    "Fan-in: total the inside metric across every recorded render."
@without_provenance
aggregate() {
    local count total
    count=$(knit query sql --exec "SELECT count(*) FROM render;")
    total=$(knit query sql --exec "SELECT sum(inside) FROM render;")

    printf 'Summed inside=%s over %s render(s).\n' "${total:-0}" "${count:-0}"
}
@done

knit "$@"
