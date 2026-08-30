#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- STEP 6: query and fan-in. The experiment (setup, `julia`
# job, `render` app) is unchanged from Step 5; this step adds an `aggregate`
# command that reads back the `inside` metric every render recorded and sums it
# across all of them. Along with `knit query catalog` / `sql` / `graph`, it shows
# how the rows the runs left behind are read after the fact.
#
# Source-only: building the setup needs a live Spack, a compiler, an MPI, and
# network access, and launching needs an MPI launcher, none of which run in plain
# CI, so check-docs only syntax-checks this file. Behavior was validated live
# during development.

source knit.sh

@set_program_description "Render a Julia-set fractal."

# Setup: unchanged from Step 4 --- an MPI-capable build that also provides a
# launcher where the machine has none.
@setup "juliaenv" "Build and install julia-fractal with MPI."
@with_spack_specs "cmake" "libpng" "mpi"
@provides_launcher
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

# The `julia` job --- unchanged from Step 5. Launches the render app across one
# rank per allocated node with `knit run`.
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

# The `render` app --- unchanged from Step 5. Records the `inside` metric from
# rank 0 into the `render` table.
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

# START aggregate
@command "aggregate" \
    "Fan-in: total the inside metric across every recorded render."
@without_provenance
aggregate() {
    # Read back what the renders recorded. Each `knit run -- render` wrote one row
    # in the `render` table (rank 0 only), so one SELECT sees every image the
    # experiment has produced, across every job submission.
    local count total
    count=$(knit query sql --exec "SELECT count(*) FROM render;")
    total=$(knit query sql --exec "SELECT sum(inside) FROM render;")

    printf 'Summed inside=%s over %s render(s).\n' "${total:-0}" "${count:-0}"
}
@done
# END aggregate

knit "$@"
