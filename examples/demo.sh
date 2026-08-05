#!/usr/bin/env bash
#
# =============================================================================
#  knit — a demo built around a real MPI application (examples/demo.sh)
# =============================================================================
#
# This is a complete, runnable knit experiment built around the real
# julia-fractal MPI program (github.com/knit-sh/julia-fractal-example): it
# renders a Julia-set fractal to a PNG in genuine parallel and records a computed
# metric for every render. Unlike examples/full.sh (whose "applications" are Bash
# functions), this demo builds and launches a real C++/MPI binary.
#
# Along the way it exercises: bootstrap (with automatic Spack provisioning); a
# command usable before bootstrap (preflight); a Spack-backed setup that
# git-clones, CMake-builds and installs external code and provides its own MPI
# launcher (knit_provides_launcher); a job declaring that setup with
# knit_with_setup, with job-state tracking and knit_job_hostnames; an app
# launched with `knit run` for real MPI across the allocation (placement options
# and native_cmd recording); knit_output recording a computed metric and an
# artifact path; and an analyze step that reads the results back with `knit query`
# (schema catalog, read-only SQL, and Cypher over the provenance graph), with
# knit_as provenance aliasing shown in the comments.
#
# It is organised around the knit experiment model — a single pipeline:
#
#   bootstrap  →  setup      →  submit (job)  →  run (app)      →  analyze
#   provision     build deps    schedule work    fan out to MPI    fan in:
#   tooling       (juliaenv)    (render)         ranks (julia)     query results
#
# HOW TO USE THIS FILE
# --------------------
# Read the numbered walkthrough below and run the commands one at a time from the
# directory that contains this script and knit.sh. Each command has its own
# fuller section further down (the walkthrough steps point to them). The same
# script runs unchanged on a laptop (--procs 1, local execution) and on an HPC
# login node (submit --nodes N -- render --procs M across a Slurm/PBS
# allocation) — that portability is the whole point of knit.
#
# Prerequisites: bash, make, git, curl/tar, and a C/C++ compiler. Step 1's
# `preflight` checks for them. Everything knit installs lives under ./.knit,
# ./setups and ./jobs, and is removed with `rm -rf .knit setups jobs`.
#
# -----------------------------------------------------------------------------
# 0. Build knit.sh (once, from the repo root)
# -----------------------------------------------------------------------------
#   make                 # concatenates src/*.sh into ./knit.sh
#   cd examples          # this script sources ./knit.sh (a symlink to ../knit.sh)
#
# From here on, all commands are run as ./demo.sh <command> ...
#
# -----------------------------------------------------------------------------
# 1. Discover the interface — and check prerequisites before bootstrap
# -----------------------------------------------------------------------------
#   ./demo.sh --help                 # the command list; every command takes --help
#   ./demo.sh preflight              # usable BEFORE bootstrap (preflight section)
#
# On a fresh checkout `--help` lists only the commands that work before bootstrap
# (bootstrap, describe, profile, and this experiment's preflight); the rest are
# refused with a "requires bootstrap" message until step 2.
#
# -----------------------------------------------------------------------------
# 2. bootstrap — provision the tooling (the first arrow of the pipeline)
# -----------------------------------------------------------------------------
#   ./demo.sh bootstrap --project julia-demo
#
# Creates ./.knit, makes sqlite and jq available, and — because a Spack-backed
# setup is declared (step 3) — provisions a knit-private Spack (a curl+tar
# download, a few minutes the first time). On a cluster, pass --profile / the
# scheduler options as in examples/full.sh. If this machine has a system MPI
# launcher that cannot launch the setup's own MPI, bootstrap once with
# --launcher none so the setup supplies the launcher instead (juliaenv section).
#
# -----------------------------------------------------------------------------
# 3. setup juliaenv — build the app and its dependencies (the `setup` step)
# -----------------------------------------------------------------------------
#   ./demo.sh setup --name juliaenv -- juliaenv
#
# Builds cmake/mpi/libpng with Spack, git-clones julia-fractal at its pinned tag,
# and CMake-builds/installs it into ./setups/juliaenv. Pin a different revision
# with `-- juliaenv --ref main` (juliaenv section).
#
# -----------------------------------------------------------------------------
# 4. submit render → run julia — schedule the work and FAN OUT to MPI ranks
# -----------------------------------------------------------------------------
#   ./demo.sh submit --setup juliaenv --wait -- render --procs 1           # laptop
#   ./demo.sh submit --setup juliaenv --nodes 2 --wait -- render --procs 8 # cluster
#
# The `render` job (the `submit` step) declares the juliaenv setup and its body
# calls `knit run --procs N -- julia`. That launches one `julia` app rank per MPI
# process (the `run` step); the ranks collaborate on julia-fractal's real
# MPI_Gather, and rank 0 writes the PNG and records the metric. This is the
# fan-out: one job, many ranks (render and julia sections).
#
# Run it a few times with different --colormap / --zoom to give `analyze`
# something to aggregate:
#   ./demo.sh submit --setup juliaenv --wait -- render --colormap ocean --zoom 2
#   ./demo.sh submit --setup juliaenv --wait -- render --colormap grayscale --zoom 4
#
# -----------------------------------------------------------------------------
# 5. analyze — FAN IN: query the results back into one summary
# -----------------------------------------------------------------------------
#   ./demo.sh analyze
#
# Runs all three `knit query` surfaces live over the recorded rows and the
# provenance graph: the schema catalog, read-only SQL ranking the renders by
# metric, and Cypher graph queries for placement and the setup→…→julia chain.
# `analyze` is a pure read (knit_without_provenance) — it records nothing, so
# inspecting the graph does not change it (analyze section).
#
# -----------------------------------------------------------------------------
# Provenance and knit_as (shown here, not exercised live)
# -----------------------------------------------------------------------------
# Everything above is also a provenance graph: `submit --setup ...` records a
# `used_by` edge from the setup to the job, and each command that invokes another
# records a `call` edge. Step 5's graph queries traverse exactly those edges.
#
# To tell repeated calls of the SAME command apart, wrap each with
# `knit_as <alias>`. A driver job could render twice under two aliases:
#   knit_as wide knit run --procs 4 -- julia --output wide.png --zoom 1
#   knit_as deep knit run --procs 4 -- julia --output deep.png --zoom 40
# then select one edge in a graph query with the inline form
# `-[{alias:'deep'}]->` or `WHERE e.alias = 'deep'`. This demo keeps a single
# `render` job, so knit_as stays in the comments rather than run live.
#
# -----------------------------------------------------------------------------
# 6. Clean up
# -----------------------------------------------------------------------------
#   rm -rf .knit setups jobs
#
# Removes knit's private tooling and database (.knit), every setup (setups/), and
# every job's working directory (jobs/).
# =============================================================================
#
# Run from the directory that contains this script and knit.sh, as
# ./demo.sh <command> ...
# -----------------------------------------------------------------------------

# Source knit.sh. This requires knit.sh to sit next to this script: the re-entry
# paths (submit, run) arrange for the experiment to be sourced from the script's
# directory so this bare form resolves even though the body runs elsewhere.
source knit.sh

knit_set_program_description \
    "A knit demo: render a Julia-set fractal with real MPI, then query the results."

# -----------------------------------------------------------------------------
# preflight (walkthrough step 1) — a command that is usable *before* bootstrap.
#
# Declared with knit_usable_before_bootstrap, so it appears in `--help` and runs
# on a fresh checkout (before ./.knit exists). Such commands must not declare a
# table or use --when: both would silently do nothing before bootstrap. This one
# reports whether the host has the tools bootstrap and the juliaenv setup need:
# git to clone the source, a C/C++ compiler to build it (and for Spack), and
# curl/tar for bootstrap's provisioning. cmake/mpi/libpng are provided by the
# setup's Spack environment, so they are not checked here.
# -----------------------------------------------------------------------------
knit_register preflight "preflight" "Check this machine has what bootstrap and the setup need (usable before bootstrap)."
knit_usable_before_bootstrap
preflight() {
    local ok=0 tool

    # A C/C++ compiler may be present as either c++ or cc; accept either.
    if command -v c++ >/dev/null 2>&1 || command -v cc >/dev/null 2>&1; then
        printf '  %-8s found\n' "c++/cc"
    else
        printf '  %-8s MISSING\n' "c++/cc"
        ok=1
    fi

    for tool in git curl tar; do
        if command -v "${tool}" >/dev/null 2>&1; then
            printf '  %-8s found\n' "${tool}"
        else
            printf '  %-8s MISSING\n' "${tool}"
            ok=1
        fi
    done

    if [[ "${ok}" -eq 0 ]]; then
        printf 'All prerequisites present — ready to bootstrap.\n'
        printf 'bootstrap will provision: sqlite + jq (under ./.knit) and, because a\n'
        printf 'Spack-backed setup is declared, a knit-private Spack (cmake/mpi/libpng).\n'
    else
        printf 'Some prerequisites are missing (see above).\n'
    fi
    return "${ok}"
}
knit_done

# -----------------------------------------------------------------------------
# juliaenv (walkthrough step 3) — the `setup` step: build julia-fractal's real
# dependencies and the app itself into the setup prefix.
#
# knit_with_spack_specs declares a Spack environment mirroring the repo's own
# spack.yaml (cmake, mpi, libpng). knit builds and activates it as the setup's
# first step — so cmake, an MPI (mpicc), and libpng are on PATH before the body
# runs — and captures the concrete spack.yaml / spack.lock as DB provenance.
# Because a Spack-backed setup is declared, `bootstrap` provisions the
# knit-private Spack automatically (curl+tar, no git needed).
#
# We use knit_with_spack_specs (not the knit_with_spack_env file form) because
# the repo — and thus its spack.yaml — does not exist until the body clones it;
# the environment must be built before the body runs.
#
# The setup then clones the (public) julia-fractal source, checks out the
# requested git ref, and CMake-configures/builds/installs it into the setup
# prefix. A full clone + checkout handles a tag, branch, OR commit uniformly (a
# shallow --branch clone cannot fetch an arbitrary commit SHA). The `ref`
# parameter is a declared column, so the resolved ref is recorded on the setup
# row for provenance on its own. Exporting PATH puts the installed julia-fractal
# binary in scope for every job that requires this setup (and the launcher
# forwards it to the MPI ranks).
#
# Because this setup builds its own MPI (the `mpi` spec above), it also builds
# that MPI's launcher (mpirun/mpiexec). knit_provides_launcher declares this: at
# build time knit detects the launcher the setup put on PATH and freezes it as
# the setup's launcher contract, so `knit run` fans out with the *matching*
# launcher on a machine that has no integrated one of its own (e.g. a laptop).
# It sits below a machine's own launcher in precedence, so on a cluster the
# site launcher (srun/PBS mpiexec) still wins. If a laptop has a *different*
# system MPI whose launcher would be preferred but cannot launch this setup's
# MPI, bootstrap once with `--launcher none` to tell knit the machine offers no
# integrated launcher, so this contract is used.
#
# Build it (auto-provisioning Spack on first bootstrap):
#   ./demo.sh setup --name juliaenv -- juliaenv
# or pin a different revision:
#   ./demo.sh setup --name juliaenv -- juliaenv --ref main
# -----------------------------------------------------------------------------
knit_register_setup "juliaenv" _juliaenv_setup "Build & install julia-fractal from source."
knit_with_spack_specs "cmake" "mpi" "libpng"
knit_provides_launcher
knit_with_optional "ref:string" "v1.0.0" "git ref to build (tag, branch, or commit)."
_juliaenv_setup() {
    # The Spack environment is already built and activated here, so cmake, mpicc,
    # and libpng from the specs above are on PATH / LD_LIBRARY_PATH.
    local ref
    ref="$(knit_get_parameter ref "$@")"

    git clone "https://github.com/knit-sh/julia-fractal-example.git" \
        "${KNIT_SETUP_PREFIX}/src"
    git -C "${KNIT_SETUP_PREFIX}/src" checkout "${ref}"

    cmake -S "${KNIT_SETUP_PREFIX}/src" -B "${KNIT_SETUP_PREFIX}/build" \
        -DCMAKE_INSTALL_PREFIX="${KNIT_SETUP_PREFIX}"
    cmake --build "${KNIT_SETUP_PREFIX}/build"
    cmake --install "${KNIT_SETUP_PREFIX}/build"

    # Put the installed binary on PATH for dependent jobs; captured into
    # .activate.sh next to the Spack re-activation block and inherited by jobs.
    export PATH="${KNIT_SETUP_PREFIX}/bin:${PATH}"
}
knit_done

# -----------------------------------------------------------------------------
# julia (walkthrough step 4, the fan-out) — the `run` step: one MPI rank of the
# julia-fractal renderer.
#
# Apps are launched by `knit run`, which starts one copy (rank) per MPI process
# of the surrounding job's allocation. This app is a thin wrapper that CALLS the
# real julia-fractal binary as a child (no exec): the child inherits this rank's
# PMI/PMIx environment and so joins the same size-N MPI world, where it runs its
# own row-decomposition and MPI_Gather. The binary must run on EVERY rank (all
# ranks participate in that collective); only its rank 0 prints the machine-
# readable "inside=<count>" line and writes the PNG.
#
# Because the body returns (no exec), the app records its own per-app row: on
# rank 0 it parses inside= from the binary's stdout and stores the metric and the
# image path with knit_output. Only rank 0 has that line and the PNG, so the
# record step is guarded on KNIT_MPI_RANK (the per-rank index knit exports). knit
# also suppresses recording on non-zero ranks, but calling knit_output there
# would still emit an "output discarded" warning per rank — the guard keeps the
# output clean and shows the intended rank-0 recording pattern.
#
# julia-fractal is found on PATH via the juliaenv setup's .activate.sh, which the
# job inherits and the launcher forwards to every rank.
# -----------------------------------------------------------------------------
knit_register_app "julia" _julia_app "One MPI rank of the julia-fractal renderer."
knit_with_optional "width:integer"    "800"     "Image width in pixels."
knit_with_optional "height:integer"   "600"     "Image height in pixels."
knit_with_optional "c-re:real"        "-0.8"    "Real part of the Julia constant c."
knit_with_optional "c-im:real"        "0.156"   "Imaginary part of the Julia constant c."
knit_with_optional "max-iter:integer" "1000"    "Maximum iterations per pixel."
knit_with_optional "colormap:string"  "fire"    "Palette: grayscale | fire | ocean."
knit_with_optional "center-x:real"    "0"       "Real-axis center of the view."
knit_with_optional "center-y:real"    "0"       "Imaginary-axis center of the view."
knit_with_optional "zoom:real"        "1"       "Zoom factor (higher = closer in)."
knit_with_required "output:string"              "PNG path (the render job supplies a per-run path)."
knit_with_output   "inside:integer" "0"         "Grid points inside the set (recorded by rank 0)."
knit_with_output   "image:string"   ""          "Path to the produced PNG (recorded by rank 0)."
_julia_app() {
    local width height c_re c_im max_iter colormap center_x center_y zoom output
    width=$(knit_get_parameter "width" "$@")
    height=$(knit_get_parameter "height" "$@")
    c_re=$(knit_get_parameter "c-re" "$@")
    c_im=$(knit_get_parameter "c-im" "$@")
    max_iter=$(knit_get_parameter "max-iter" "$@")
    colormap=$(knit_get_parameter "colormap" "$@")
    center_x=$(knit_get_parameter "center-x" "$@")
    center_y=$(knit_get_parameter "center-y" "$@")
    zoom=$(knit_get_parameter "zoom" "$@")
    output=$(knit_get_parameter "output" "$@")

    # Positional order the binary expects:
    #   width height c_re c_im max_iter output colormap center_x center_y zoom
    local out
    out=$(julia-fractal "${width}" "${height}" "${c_re}" "${c_im}" "${max_iter}" \
        "${output}" "${colormap}" "${center_x}" "${center_y}" "${zoom}")
    printf '%s\n' "${out}"

    # Only rank 0 printed the metric line and wrote the PNG, so record from there.
    if [[ "${KNIT_MPI_RANK:-0}" == 0 ]]; then
        local inside
        inside=$(sed -n 's/.*inside=\([0-9]*\).*/\1/p' <<<"${out}" | head -1)
        knit_output "inside" "${inside}"
        knit_output "image"  "${output}"
    fi
}
knit_done

# -----------------------------------------------------------------------------
# render (walkthrough step 4) — the `submit` step: a job that renders a fractal
# as MPI work.
#
# The job stays thin: it declares its setup dependency with knit_with_setup
# "juliaenv" (so knit builds/activates that setup's environment, putting
# julia-fractal on PATH, before the body runs) and forwards its render options to
# the app. Its body calls `knit run` to fan out: one julia rank per MPI process
# across the job's allocation. The metric and image are recorded by the app (on
# rank 0); the runs row records the placement.
#
# Portable by default: --procs 1 runs anywhere (singleton MPI), including a
# laptop with no launcher. On a cluster, submit with more nodes and a higher
# --procs to spread ranks across the allocation:
#   ./demo.sh submit --setup juliaenv --wait -- render --procs 1
#   ./demo.sh submit --setup juliaenv --nodes 2 -- render --procs 8
# -----------------------------------------------------------------------------
knit_register_job "render" _render_job "Render a Julia fractal as a submitted MPI job."
knit_with_setup    "juliaenv"
knit_with_optional "procs:integer"    "1"       "MPI ranks to launch (scale up on a cluster)."
knit_with_optional "width:integer"    "800"     "Image width in pixels."
knit_with_optional "height:integer"   "600"     "Image height in pixels."
knit_with_optional "c-re:real"        "-0.8"    "Real part of the Julia constant c."
knit_with_optional "c-im:real"        "0.156"   "Imaginary part of the Julia constant c."
knit_with_optional "max-iter:integer" "1000"    "Maximum iterations per pixel."
knit_with_optional "colormap:string"  "fire"    "Palette: grayscale | fire | ocean."
knit_with_optional "center-x:real"    "0"       "Real-axis center of the view."
knit_with_optional "center-y:real"    "0"       "Imaginary-axis center of the view."
knit_with_optional "zoom:real"        "1"       "Zoom factor (higher = closer in)."
_render_job() {
    local procs
    procs=$(knit_get_parameter "procs" "$@")

    # A per-run PNG under this job's directory, so each render keeps its own image.
    local png="${KNIT_JOB_PREFIX%/}/fractal.png"

    # Fan out: one julia rank per MPI process, forwarding the render options.
    knit run --procs "${procs}" -- julia \
        --output   "${png}" \
        --width    "$(knit_get_parameter width "$@")" \
        --height   "$(knit_get_parameter height "$@")" \
        --c-re     "$(knit_get_parameter c-re "$@")" \
        --c-im     "$(knit_get_parameter c-im "$@")" \
        --max-iter "$(knit_get_parameter max-iter "$@")" \
        --colormap "$(knit_get_parameter colormap "$@")" \
        --center-x "$(knit_get_parameter center-x "$@")" \
        --center-y "$(knit_get_parameter center-y "$@")" \
        --zoom     "$(knit_get_parameter zoom "$@")"

    printf 'rendered %s on %s\n' "${png}" "$(knit_job_hostnames --separator ', ')"
}
knit_done

# -----------------------------------------------------------------------------
# analyze (walkthrough step 5) — the `analyze` step: fan the results back in with
# `knit query`.
#
# After one or more render jobs have fanned out and each recorded its metric,
# this step fans the data back in: it queries the recorded rows and the
# provenance graph and prints a summary the team can read at a glance. It is the
# closing step of the pipeline (bootstrap → setup → submit → run → analyze).
#
# knit_without_provenance marks it a pure read: running analyze records no row
# and adds no edge, so inspecting the graph does not pollute it (like `knit query`
# itself). It declares no table for the same reason.
#
# It exercises all three query surfaces live:
#   - `knit query catalog` — the schema, with each table annotated by the command
#     that owns it (e.g. jobs ← submit, runs ← run);
#   - `knit query sql`     — knit's read-only SQL path over the julia app rows;
#   - `knit query graph`   — Cypher over the provenance, resolved by knit-graph.
#
# Graph labels are the table names (jobs/render/runs/julia) and the setup's own
# name (setup:juliaenv, backtick-quoted for the colon); edges are `call` (a
# command invoking another) and `used_by` (a setup consumed by a submission). A
# bare (render) would be a *variable*, not a label — labels take the (var:label)
# form. The metric lives on the per-app `julia` row, so the queries reach all the
# way to julia.inside / julia.image.
#
#   ./demo.sh analyze
# -----------------------------------------------------------------------------
knit_register _analyze "analyze" "Summarise every render: metric, placement, provenance."
knit_without_provenance
_analyze() {
    printf '== schema (catalog) ==\n'
    knit query catalog

    printf '\n== renders ranked by metric (SQL over the julia app rows) ==\n'
    knit query sql --header --format table --exec \
        "SELECT colormap, zoom, inside, image FROM julia ORDER BY inside DESC"

    printf '\n== placement of each launch (graph: render -call-> runs) ==\n'
    knit query graph --header --format table --exec \
        "MATCH (rr:render)-[:call]->(r:runs) RETURN r.app, r.procs, r.hostnames"

    printf '\n== renders that used the juliaenv setup (graph: the used_by chain) ==\n'
    knit query graph --header --format table --exec \
        "MATCH (s:\`setup:juliaenv\`)-[:used_by]->(j:jobs)-[:call]->(rr:render)
                -[:call]->(:runs)-[:call]->(a:julia)
         RETURN a.colormap, a.inside, a.image ORDER BY a.inside DESC"
}
knit_done

# -----------------------------------------------------------------------------
# Call the main entry point of the knit framework (must come last).
# -----------------------------------------------------------------------------
knit "$@"
