#!/bin/bash

# doc-check: source-only
#
# The complete Part II experiment: the same julia-fractal experiment Part I
# built, refined piece by piece. A git RESOURCE feeds the setup, a shared
# PARAMETER SET and a colormap ENUM remove the duplicated parameters, the app
# records its PNG as a checksummed FILE OUTPUT, and the fan-in produces a result
# ARTIFACT from a graph query. This is the final state after Part II's Steps 1--5;
# Steps 6 (prepare) and 7 (remove) are console workflows over this same script.
#
# Source-only: building the setup needs a live Spack, a compiler, an MPI, and
# network access, and launching needs an MPI launcher, none of which run in plain
# CI, so check-docs only syntax-checks this file. Behavior was validated live
# during development.

source knit.sh

knit_set_program_description "Render a Julia-set fractal."

# --- Resource ---------------------------------------------------------------
# The julia-fractal source, acquired once with `knit fetch` and recorded at its
# resolved commit. A resource has no body; a download decorator says where it
# comes from. Fetch a named instance with `fetch --name <n> -- julia_code`.
@resource "julia_code" "The julia-fractal source (github.com/knit-sh/julia-fractal-example)."
@with_git "https://github.com/knit-sh/julia-fractal-example.git" "v1.1.0"
@done

# --- Setup ------------------------------------------------------------------
# Builds and installs julia-fractal with MPI from the fetched source instead of
# cloning it inline. It declares the resource it needs (up-front validation and a
# `used_by` edge) and resolves the name to a path. Spack provisions the build
# dependencies; on a machine with no launcher of its own, the setup provides one.
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
# A user-defined, validated type. `--colormap purple` is refused up front, and
# `describe`/`--help` advertise the choices.
@enum "colormap" "grayscale" "fire" "ocean"

# --- Parameter set ----------------------------------------------------------
# The six shared parameters, defined once and imported by both the job and the
# app. A conflicting redefinition on import is fatal. `colormap` uses the enum.
@parameter_set "julia-params"
@with_optional "width:integer"     "800"    "Image width in pixels."
@with_optional "height:integer"    "600"    "Image height in pixels."
@with_optional "c-re:real"         "-0.8"   "Real part of the Julia constant c."
@with_optional "c-im:real"         "0.156"  "Imaginary part of the Julia constant c."
@with_optional "max-iter:integer"  "1000"   "Maximum iterations per pixel."
@with_optional "colormap:colormap" "fire"   "Palette: $(knit_enum_values colormap ", ")."
@done

# --- Job --------------------------------------------------------------------
# Submitted to the scheduler. Imports the shared set and keeps its own `output`
# name. Its body launches the render app across one rank per allocated node with
# `knit run`, so the same job runs one rank on a laptop and one rank per node
# across a multi-node allocation.
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
# One MPI-parallel image. Imports the shared set. Rank 0 records the `inside`
# metric and the produced PNG as a checksummed `file` output (an intermediate
# that stays in the job directory, with an `image_checksum` column on this table).
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
# Produces a result instead of just printing one. It records its own row and
# provenance (no @without_provenance), builds a CSV straight from the provenance
# graph with a Cypher query, and declares that CSV as a result ARTIFACT: a row in
# the artifacts table, a `produced` edge, a content checksum, and a path stored
# relative to the artifacts root.
@command "aggregate" "Fan-in: tabulate every render into a result CSV."
@with_table
@with_artifact "table:file" "Per-render inside metric, one row per image (CSV)." --result
aggregate() {
    local out
    out="$(knit_artifact_dir)"
    mkdir -p "${out}"

    knit query graph --format csv --header --exec \
        "MATCH (r:run)-[:call]->(img:render)
         RETURN img.c_re AS c_re, img.c_im AS c_im, img.inside AS inside" \
        > "${out}/inside.csv"

    knit_artifact "table" "inside.csv"

    printf 'wrote %s\n' "${out}/inside.csv"
}
@done

knit "$@"
