#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- STEP 5: the `julia` job stops running the binary directly
# and instead launches it across MPI ranks with `knit run`. The parallel work is
# wrapped in a new *app* called `render` (the unit `knit run` launches per rank).
# The job body barely changes --- only its final line --- and the setup is
# unchanged from Step 4.
#
# Source-only: building the setup needs a live Spack, a compiler, an MPI, and
# network access, and launching needs an MPI launcher, none of which run in plain
# CI, so check-docs only syntax-checks this file. Behavior was validated live
# during development.

source knit.sh

knit_set_program_description "Render a Julia-set fractal."

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

    local png="${KNIT_JOB_PREFIX%/}/fractal.png"

    # Report where the scheduler placed this job.
    printf 'The job is running on hosts: %s\n' \
        "$(knit_job_hostnames --separator ', ')"

    # Was (Step 4): julia-fractal "${width}" ... "${png}" "${colormap}"
    # Now: launch the render app instead of running the binary here, with one rank
    # per allocated node. knit_job_nodecount is 1 on a laptop, so this runs
    # anywhere; on a cluster it scales with the nodes the job was given (submit
    # --nodes N). The values we used to pass positionally become named parameters.
    knit run --procs "$(knit_job_nodecount)" --procs-per-node 1 -- render \
        --width "${width}" --height "${height}" \
        --c-re "${c_re}" --c-im "${c_im}" --max-iter "${max_iter}" \
        --colormap "${colormap}" --output "${png}"
}
@done
# END job

# START app
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

    # This body runs on EVERY rank: knit run launched one copy per rank, and
    # julia-fractal --- called as a child, not exec'd --- inherits the launcher's
    # MPI environment, so the copies form one MPI world and split the image. Only
    # rank 0 writes the PNG and prints the inside= line.
    local out
    out=$(julia-fractal "${width}" "${height}" "${c_re}" "${c_im}" "${max_iter}" \
        "${output}" "${colormap}")
    printf '%s\n' "${out}"

    # Record the metric. Knit records outputs only from rank 0 (it suppresses
    # recording on the other ranks), so this single knit_output writes one row no
    # matter how many ranks ran. KNIT_MPI_RANK / KNIT_MPI_SIZE / KNIT_MPI_LOCAL_RANK
    # are available too if a body needs to branch on its own rank.
    local inside
    inside=$(sed -n 's/.*inside=\([0-9]*\).*/\1/p' <<< "${out}" | head -1)
    knit_output "inside" "${inside}"
}
@done
# END app

knit "$@"
