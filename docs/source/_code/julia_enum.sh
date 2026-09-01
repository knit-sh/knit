#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- PART II, section 3 (Enums): `colormap` becomes a
# user-defined, validated type. An @enum declares the three accepted palettes,
# and the shared parameter in the `julia-params` set changes from `colormap:string`
# to `colormap:colormap`. A value outside the enum is now refused up front, and
# `describe` / `--help` advertise the choices. Everything else --- the git
# resource, the setup, the parameter set, the job, the app, the fan-in --- is
# unchanged from section 2.
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

# --- Enum -------------------------------------------------------------------
# START enum
# An enum is a named type with a fixed set of values. Declaring `colormap` here
# lets any parameter be typed `:colormap`; Knit then rejects a value outside the
# set before the command body runs.
@enum "colormap" "grayscale" "fire" "ocean"
# END enum

# --- Parameter set ----------------------------------------------------------
# START pset
# The shared set is unchanged except for `colormap`, which is now typed with the
# enum above instead of a free `string`. `knit_enum_values` builds the help text
# from the same source, so the list of palettes cannot drift from the type.
@parameter_set "julia-params"
@with_optional "width:integer"     "800"    "Image width in pixels."
@with_optional "height:integer"    "600"    "Image height in pixels."
@with_optional "c-re:real"         "-0.8"   "Real part of the Julia constant c."
@with_optional "c-im:real"         "0.156"  "Imaginary part of the Julia constant c."
@with_optional "max-iter:integer"  "1000"   "Maximum iterations per pixel."
@with_optional "colormap:colormap" "fire"   "Palette: $(knit_enum_values colormap ", ")."
@done
# END pset

# --- Job --------------------------------------------------------------------
# The job imports the shared parameters with @with_parameter_set (see section 2)
# and keeps its own `output` parameter and setup dependency.
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

# --- App --------------------------------------------------------------------
# The app imports the SAME parameter set, so it inherits the enum-typed colormap
# too. `output` differs from the job's (required here) so it stays per-command.
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
