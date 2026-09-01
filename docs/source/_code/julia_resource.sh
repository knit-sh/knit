#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- PART II, section 1 (Resources): the setup no longer
# clones julia-fractal inline. The source is a `julia_code` git resource,
# fetched once with `knit fetch` and declared by the setup with @with_resource.
# Everything else (the job, the app, the fan-in) is unchanged from Part I.
#
# Source-only: building the setup needs a live Spack, a compiler, an MPI, and
# network access, none of which run in plain CI, so check-docs only syntax-checks
# this file. Behavior was validated live during development.

source knit.sh

knit_set_program_description "Render a Julia-set fractal."

# --- Resource ---------------------------------------------------------------
# START resource
# A resource declares HOW to acquire an input --- here the julia-fractal source,
# as a git repository pinned to a default ref. It has no body: `knit fetch`
# clones it once into the resources directory, makes it read-only, and records
# the resolved commit for provenance. Fetch a named instance with
#   ./exp.sh fetch --name julia_src -- julia_code
# and pin a different revision with `--ref` when you fetch.
@resource "julia_code" "The julia-fractal source (github.com/knit-sh/julia-fractal-example)."
@with_git "https://github.com/knit-sh/julia-fractal-example.git" "v1.1.0"
@done
# END resource

# --- Setup ------------------------------------------------------------------
# START setup
# The setup no longer clones anything. It DECLARES that it needs the source with
# @with_resource "src:julia_code": Knit checks the named instance was fetched
# (and is of type julia_code) before the body runs, and records a used_by edge
# from the resource to the setup. The body turns the instance name into its
# on-disk path with knit_resource_path.
@setup "juliaenv" "Build and install julia-fractal with MPI from fetched source."
@with_resource "src:julia_code" "Name of the fetched julia-fractal source to build."
@with_spack_specs "cmake" "libpng" "mpi"
@provides_launcher
_juliaenv_setup() {
    # A fetched instance is read-only, so we build OUT of source --- a separate
    # build/ tree under the setup prefix --- and never write back into it.
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
# END setup

# --- Job --------------------------------------------------------------------
# Submitted to the scheduler. Its body launches the render app across one rank
# per allocated node with `knit run`, so the same job runs one rank on a laptop
# and one rank per node across a multi-node allocation.
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
# One MPI-parallel image. Launched by the job via `knit run`; it inherits the
# job's setup environment, so julia-fractal is already on PATH. Rank 0 records
# the `inside` metric into the `render` table.
@app "render" "Render one MPI-parallel Julia-set image."
@with_optional "width:integer"    "800"    "Image width in pixels."
@with_optional "height:integer"   "600"    "Image height in pixels."
@with_optional "c-re:real"        "-0.8"   "Real part of the Julia constant c."
@with_optional "c-im:real"        "0.156"  "Imaginary part of the Julia constant c."
@with_optional "max-iter:integer" "1000"   "Maximum iterations per pixel."
@with_optional "colormap:string"  "fire"   "Palette: grayscale | fire | ocean."
@with_required "output:string"             "Absolute PNG path (the job supplies one per run)."
@with_output   "inside:integer"   "0"      "Grid points inside the set (recorded by rank 0)."
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
# Reads back what the renders recorded. `@without_provenance` marks this as
# read-only bookkeeping, so it writes no row or edge of its own. Each
# `knit run -- render` wrote one row in the `render` table, so a single SELECT
# sees every image the experiment has produced.
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
