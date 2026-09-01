#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- PART II, section 4 (File output and checksum): the
# `render` app now records the PNG it produces as a `file` OUTPUT. Declaring
# `image:file` makes Knit check the file exists when the app finishes and record
# its SHA-256 digest in an `image_checksum` column on the `render` table. The PNG
# stays where the job wrote it, as a checksummed intermediate. The location
# inputs also gain intent: both the job's and the app's `output` become a
# `filename` --- the unchecked counterpart of `file` --- instead of a bare
# `string`. Everything else --- the git resource, the setup, the enum, the
# parameter set, the fan-in --- is unchanged from section 3.
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
# The `colormap` type (see section 3).
@enum "colormap" "grayscale" "fire" "ocean"

# --- Parameter set ----------------------------------------------------------
# The shared parameters, imported by the job and the app (see sections 2 and 3).
@parameter_set "julia-params"
@with_optional "width:integer"     "800"    "Image width in pixels."
@with_optional "height:integer"    "600"    "Image height in pixels."
@with_optional "c-re:real"         "-0.8"   "Real part of the Julia constant c."
@with_optional "c-im:real"         "0.156"  "Imaginary part of the Julia constant c."
@with_optional "max-iter:integer"  "1000"   "Maximum iterations per pixel."
@with_optional "colormap:colormap" "fire"   "Palette: $(knit_enum_values colormap ", ")."
@done

# --- Job --------------------------------------------------------------------
# Unchanged from section 3: imports the shared set, keeps its own `output`.
@job "julia" "Render a Julia-set fractal as a submitted job."
@with_setup "juliaenv"
@with_parameter_set "julia-params"
@with_optional "output:filename" "fractal.png" "PNG file name, written in the job directory."
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
# START app
# `output` is a `filename` INPUT: the location the job hands in. `filename` is the
# unchecked counterpart of `file` --- Knit does not require it to exist, because
# the render has not written it yet. `image:file` is the OUTPUT: `knit_output
# "image"` binds the produced PNG, and because it is a `file`, Knit checks it
# exists at completion and records its SHA-256 in the `image_checksum` column.
@app "render" "Render one MPI-parallel Julia-set image."
@with_parameter_set "julia-params"
@with_required "output:filename"         "Absolute PNG path (the job supplies one per run)."
@with_output   "inside:integer"   "0"    "Grid points inside the set (recorded by rank 0)."
@with_output   "image:file"       ""     "The PNG this render produced (checksummed intermediate)."
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

    # Bind the produced PNG. Knit verifies it exists and records its checksum.
    knit_output "image" "${output}"
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
