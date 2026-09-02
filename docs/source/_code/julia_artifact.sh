#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- PART II, section 5 (Results and artifacts): the fan-in
# `aggregate` command stops being read-only bookkeeping and starts recording what
# it produces. It drops `@without_provenance` (so it records its own row and
# provenance), builds a CSV straight from the provenance graph with a Cypher query
# (`knit query graph --format csv`), and declares that CSV as a result ARTIFACT
# (`@with_artifact ... --result`) bound with `knit_artifact`. Everything else ---
# the git resource, the setup, the enum, the parameter set, the job, the
# file-output app --- is unchanged from section 4.
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
# Imports the shared set, keeps its own `output` name (see section 4).
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
# Records the produced PNG as a checksummed `file` output (see section 4).
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

    knit_output "image" "${output}"
}
@done

# --- Fan-in -----------------------------------------------------------------
# START aggregate
# Part I's aggregate was read-only bookkeeping (@without_provenance): it printed a
# sum and left no trace. Now it produces a result. Dropping @without_provenance
# lets it record its own row and provenance; @with_table gives it that row, and
# @with_artifact declares the CSV it writes as the headline RESULT.
@command "aggregate" "Fan-in: tabulate every render into a result CSV."
@with_table
@with_artifact "table:file" "Per-render inside metric, one row per image (CSV)." --result
aggregate() {
    # knit_artifact_dir is the artifacts/ root: write into it, then declare.
    local out
    out="$(knit_artifact_dir)"
    mkdir -p "${out}"

    # Build the table straight from the provenance graph with a Cypher query:
    # walk from each run to the render it launched, projecting the constant and
    # the inside metric. --format csv emits comma-separated rows; --header adds
    # the column names.
    knit query graph --format csv --header --exec \
        "MATCH (r:run)-[:call]->(img:render)
         RETURN img.c_re AS c_re, img.c_im AS c_im, img.inside AS inside" \
        > "${out}/inside.csv"

    # Bind the CSV as a result artifact: Knit records it as a row in the
    # framework-owned artifacts table, linked to THIS invocation by a `produced`
    # edge, with its content checksummed and its path stored relative to the
    # artifacts root (never an absolute machine path).
    knit_artifact "table" "inside.csv"

    printf 'wrote %s\n' "${out}/inside.csv"
}
@done
# END aggregate

knit "$@"
