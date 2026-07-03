#!/usr/bin/env bash
#
# =============================================================================
#  knit — a guided tour (examples/full.sh)
# =============================================================================
#
# This is a complete, runnable knit experiment. It estimates the value of pi
# with a Monte-Carlo method, and along the way it exercises every feature knit
# currently implements: bootstrapping, machine profiles, metadata, typed
# command parameters, setups (reproducible environments), and job submission
# to a batch scheduler (Slurm/PBS) — or to local background processes when no
# scheduler is present.
#
# HOW TO USE THIS FILE
# --------------------
# Read the numbered walkthrough below and run the commands one at a time from
# the directory that contains this script and knit.sh. Each step explains what
# the command does and what you should expect to see. The same script runs
# unchanged on your laptop (local backend) and on an HPC login node (Slurm/PBS)
# — that portability is the whole point of knit.
#
# Prerequisites: bash, git, make, a C compiler and curl/wget (bootstrap builds
# a private copy of sqlite and jq from source). Everything knit installs lives
# under ./.knit and is removed with `rm -rf .knit`.
#
# -----------------------------------------------------------------------------
# 0. Build knit.sh (once, from the repo root) and copy this example next to it
# -----------------------------------------------------------------------------
#   make                       # concatenates src/*.sh into ./knit.sh
#   cp knit.sh examples/       # so `source knit.sh` below finds it
#   cd examples
#
# From here on, all commands are run as ./full.sh <command> ...
#
# -----------------------------------------------------------------------------
# 1. Discover the interface
# -----------------------------------------------------------------------------
#   ./full.sh --help
#
# Prints the program description and the list of subcommands: estimate, submit,
# setup, bootstrap, metadata, profile. Every command takes --help, e.g.
#
#   ./full.sh estimate --help
#   ./full.sh submit --help
#
# The per-command help lists each parameter, its type, whether it is
# required/optional (with the default), and its description.
#
# Jobs and setups are invoked through `submit`/`setup` after a `--`, and you can
# ask for their help by name, e.g.
#
#   ./full.sh submit montecarlo --help
#   ./full.sh setup mcenv --help
#
# The usage line reflects the real grammar
# (`submit [OPTIONS] -- montecarlo [OPTIONS]`), and the help shows the job/setup's
# own options, the enclosing `submit`/`setup` options (such as `--setup` /
# `--path`), and — for a job declared with `knit_with_setup` — the setup type it
# requires.
#
# -----------------------------------------------------------------------------
# 2. Bootstrap the experiment
# -----------------------------------------------------------------------------
#   ./full.sh bootstrap --project pi-demo
#
# This creates ./.knit, downloads and BUILDS sqlite and jq from source (this
# takes a minute or two the first time), creates the ./.knit/knit.db database,
# and records some metadata. knit auto-detects the batch scheduler; on a machine
# without one it falls back to local execution and warns you. You can be
# explicit:
#
#   ./full.sh bootstrap --project pi-demo --scheduler local
#   ./full.sh bootstrap --project pi-demo --scheduler slurm --account MYALLOC
#
# If your machine has a built-in profile (see step 3), pass it to prepopulate
# the scheduler, launcher, queue, walltime cap and per-node core count:
#
#   ./full.sh bootstrap --project pi-demo --profile polaris
#
# Bootstrap is one-shot: re-running it on an already-bootstrapped experiment is
# an error. To start over, `rm -rf .knit` first.
#
# -----------------------------------------------------------------------------
# 3. Inspect the built-in machine profiles
# -----------------------------------------------------------------------------
#   ./full.sh profile list
#   ./full.sh profile show polaris
#
# Profiles are curated descriptions of known HPC systems (scheduler type,
# default queue and its caps, MPI launcher, cores/GPUs per node). `show` prints
# the profile as JSON.
#
# -----------------------------------------------------------------------------
# 4. See what bootstrap recorded
# -----------------------------------------------------------------------------
#   ./full.sh metadata show
#
# Prints the metadata key/value table: the project name, resolved scheduler and
# launcher, the default queue/walltime, detected cores per node, etc. You can
# read or write individual keys too:
#
#   ./full.sh metadata load  --key __scheduler__
#   ./full.sh metadata store --key note --value "first tour"
#   ./full.sh metadata store --key note --value "second tour" --force
#
# Storing a key that already exists fails unless you pass --force, which
# overwrites the existing value.
#
# -----------------------------------------------------------------------------
# 5. Run a quick, typed command (no scheduler involved)
# -----------------------------------------------------------------------------
#   ./full.sh estimate --samples 2000
#
# `estimate` is an ordinary knit command: it estimates pi locally and prints
# something like
#
#   pi ~= 3.16200  (2000 samples, seed 42)
#
# Because it is declared with `knit_with_table`, every run is also recorded as a
# row in the database (see step 8). Its parameters are typed:
#   --samples : integer (required)
#   --seed    : integer (optional, default 42)  -> makes results reproducible
#   --format  : enum {decimal, scientific}      -> demonstrates knit_define_enum
#   --verbose : flag                            -> prints extra info on stderr
#
#   ./full.sh estimate --samples 2000 --seed 7 --format scientific --verbose
#
# Re-running with the same --samples and --seed always yields the same estimate:
# reproducibility is knit's reason for existing.
#
# Types are checked before the command runs, so bad input is rejected up front
# rather than producing garbage or a confusing error deep in the command:
#
#   ./full.sh estimate --samples abc
#     -> [knit:fatal] Parameter --samples of "estimate" expects a value of
#        type "integer" (got "abc").
#   ./full.sh estimate --samples 10 --format ultra
#     -> [knit:fatal] Parameter --format of "estimate" expects one of:
#        decimal, scientific (got "ultra").
#
# -----------------------------------------------------------------------------
# 6. Look inside the database
# -----------------------------------------------------------------------------
# `db query` reads the database through knit, so you never touch the bundled
# sqlite binary or its path directly:
#
#   ./full.sh db query --from estimate \
#       --select "id, samples, seed, format, pi" --header --column
#
# Each `estimate` run is one row: its parameters, its declared output (pi), and
# a time-ordered UUID id. --header/--column format the output; --where,
# --order-by and --limit cover the common filters, and --sql is an escape hatch
# for arbitrary statements. `db tables` lists the tables that exist.
#
#   ./full.sh db tables
#
# Note: in the future, knit will provide further tools to simplify querying its
# database, including producing plots.
#
# -----------------------------------------------------------------------------
# 7. Create a setup (a reproducible environment)
# -----------------------------------------------------------------------------
#   ./full.sh setup --path ./env -- mcenv --seed 123
#
# A "setup" builds/prepares an environment in a directory and snapshots the
# resulting shell environment into <dir>/.activate.sh. Here `mcenv` writes a
# params file and exports MC_SEED / MC_SAMPLES. Note the `--` : arguments before
# it configure `setup`; arguments after it are passed to the named setup.
#
#   cat env/.activate.sh        # the captured environment (sourced by jobs)
#   cat env/params.txt          # written by the setup function
#
# The setup directory must not already exist; remove it to re-create it.
#
# -----------------------------------------------------------------------------
# 8. Submit a job
# -----------------------------------------------------------------------------
#   ./full.sh submit --setup ./env --wait -- montecarlo --samples 50000
#
# `submit` generates a batch script under env/jobs/<uuid>/, submits it to the
# detected scheduler (or runs it as a local background process), and prints the
# job's UUID. On the compute node the job re-hydrates the setup environment
# (sourcing .activate.sh, so MC_SEED/MC_SAMPLES are visible) and runs.
#
# `montecarlo` leaves --samples/--seed off above, so they take their ENV[...]
# defaults: knit reads MC_SAMPLES/MC_SEED from the sourced setup environment.
# Pass them explicitly (e.g. `... -- montecarlo --samples 50000 --seed 7`) to
# override the setup's values.
#
# `montecarlo` declares `knit_with_setup mcenv`, so it *requires* a setup built
# by `mcenv`: `--setup` is mandatory and must point at an mcenv setup directory.
# Point it at a directory built by another setup (or one that knit did not build)
# and submit refuses up front with a clear type-mismatch error. A job that
# declares no `knit_with_setup` needs no environment: `--setup` is optional for
# it and, when omitted, its job directory is created under ./jobs/<uuid> instead.
#
#   --wait blocks until the job finishes. Without it, submit returns immediately
#   and you poll the state yourself. Other options (see `submit --help`):
#   --nodes, --walltime, --queue, --account, --gpus-per-node, --job-name.
#
# Capture the printed UUID and inspect the job directory:
#
#   uuid=$(./full.sh submit --setup ./env --wait -- montecarlo --samples 50000)
#   cat env/jobs/$uuid/.stdout    # the job's output (pi estimate + hostname)
#   cat env/jobs/$uuid/.job.sh    # the generated batch script
#   cat env/jobs/$uuid/.job.id    # the scheduler's job id (or local PID)
#
# Every submission is tracked in the `submissions` table, and its lifecycle
# state advances submitted -> running -> completed (or -> killed if cancelled):
#
#   ./full.sh db query --from submissions \
#       --select "id, job, state" --header --column
#
# The job's own output (pi) is recorded in its own table:
#
#   ./full.sh db query --from '"submit:montecarlo"' \
#       --select "id, samples, seed, pi" --header --column
#
# -----------------------------------------------------------------------------
# 9. Clean up
# -----------------------------------------------------------------------------
#   rm -rf .knit env
#
# Removes knit's private tooling, the database, and the setup/job directories.
#
# =============================================================================
# KNOWN LIMITATIONS (as of this writing)
# =============================================================================
#   - `knit run` (MPI placement across the allocation) is not implemented, so
#     these jobs run a single process per submission.
# =============================================================================


# -----------------------------------------------------------------------------
# Implementation
# -----------------------------------------------------------------------------
# Source knit.sh relative to THIS script (not the current directory). This
# matters because `submit` re-enters the experiment from inside a job directory:
# a bare `source knit.sh` would fail there, so we resolve the path explicitly.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/knit.sh"

knit_set_program_description \
    "A guided tour of knit: estimate pi with Monte-Carlo, locally or as a job."

# A user-defined enum type, usable as a parameter type below.
knit_define_enum "numfmt" "decimal" "scientific"

# -----------------------------------------------------------------------------
# _pi_monte_carlo()
#
# Estimate pi by the Monte-Carlo method: sample points in the unit square and
# count how many fall inside the quarter circle. Seeding bash's ${RANDOM}
# makes the result deterministic for a given (samples, seed) pair, which is
# what makes runs reproducible. Prints the estimate formatted per ${format}.
#
# Note: in practice, this would simply be an external program (e.g. in C, C++,
# Python, etc.) built and installed within an environment.
#
# @param samples Number of random points to draw.
# @param seed    Seed for the pseudo-random generator.
# @param format  Output format: "decimal" or "scientific".
# -----------------------------------------------------------------------------
_pi_monte_carlo() {
    local samples="$1"
    local seed="$2"
    local format="$3"

    RANDOM="${seed}"
    local inside=0 i x y
    local max=32767              # ${RANDOM} yields 0..32767
    for (( i = 0; i < samples; i++ )); do
        x=${RANDOM}
        y=${RANDOM}
        if (( x * x + y * y <= max * max )); then
            (( inside++ ))
        fi
    done

    local awk_fmt="%.5f"
    [[ "${format}" == "scientific" ]] && awk_fmt="%.5e"
    awk -v i="${inside}" -v n="${samples}" "BEGIN { printf \"${awk_fmt}\", 4 * i / n }"
}

# -----------------------------------------------------------------------------
# estimate — a plain command: quick local pi estimate, recorded in the DB.
# -----------------------------------------------------------------------------
knit_register estimate "estimate" "Estimate pi locally with Monte-Carlo."
knit_with_required "samples:integer"       "Number of random samples to draw."
knit_with_optional "seed:integer" "42"     "PRNG seed (fixed for reproducibility)."
knit_with_optional "format:numfmt" "decimal" "Output format: decimal or scientific."
knit_with_flag     "verbose"               "Print progress information on stderr."
knit_with_table                            # record every run as a DB row
knit_with_output   "pi:real" "0"           "The estimated value of pi."
estimate() {
    local samples seed format verbose
    samples=$(knit_get_parameter "samples" "$@")
    seed=$(knit_get_parameter "seed" "$@")
    format=$(knit_get_parameter "format" "$@")
    verbose=$(knit_get_parameter "verbose" "$@")

    if [[ "${verbose}" == "true" ]]; then
        knit_info "Estimating pi with ${samples} samples (seed ${seed})..."
    fi

    local pi
    pi=$(_pi_monte_carlo "${samples}" "${seed}" "${format}")

    knit_output "pi" "${pi}"     # store the result in the DB row
    printf 'pi ~= %s  (%s samples, seed %s)\n' "${pi}" "${samples}" "${seed}"
}
knit_done

# -----------------------------------------------------------------------------
# mcenv — a setup: prepare a reproducible Monte-Carlo environment.
#
# Writes a params file into the setup directory and exports MC_SEED / MC_SAMPLES
# so that jobs depending on this setup inherit them (via .activate.sh).
# -----------------------------------------------------------------------------
knit_register_setup "mcenv" _mcenv_setup "Prepare a reproducible Monte-Carlo environment."
knit_with_optional "seed:integer" "42"        "Seed to bake into the environment."
knit_with_optional "samples:integer" "20000"  "Default sample count for jobs."
_mcenv_setup() {
    local seed samples
    seed=$(knit_get_parameter "seed" "$@")
    samples=$(knit_get_parameter "samples" "$@")

    # Files written here live alongside the setup and travel with it.
    printf 'seed=%s\nsamples=%s\n' "${seed}" "${samples}" \
        > "${KNIT_SETUP_PREFIX}/params.txt"

    # Exported variables are captured into .activate.sh and re-hydrated by jobs.
    export MC_SEED="${seed}"
    export MC_SAMPLES="${samples}"
}
knit_done

# -----------------------------------------------------------------------------
# montecarlo — a job: run the estimate on a compute node.
#
# Its --samples and --seed default to "ENV[MC_SAMPLES]" / "ENV[MC_SEED]": when
# not given on the command line, knit fills them from the MC_SAMPLES / MC_SEED
# variables exported by the activated `mcenv` setup. Passing --samples / --seed
# explicitly overrides that. Records the estimate in its own DB table.
# -----------------------------------------------------------------------------
knit_register_job "montecarlo" _montecarlo_job "Estimate pi as a submitted job."
knit_with_setup    "mcenv"                             # requires an `mcenv` setup
knit_with_optional "samples:integer" "ENV[MC_SAMPLES]" "Sample count (default: MC_SAMPLES from the setup)."
knit_with_optional "seed:integer"    "ENV[MC_SEED]"    "PRNG seed (default: MC_SEED from the setup)."
knit_with_output   "pi:real" "0"                       "The estimated value of pi."
_montecarlo_job() {
    # --samples and --seed are already resolved: either the values passed on the
    # command line, or (via their ENV[...] defaults) the ones exported by the
    # setup. No manual environment fallback is needed here.
    local samples seed
    samples=$(knit_get_parameter "samples" "$@")
    seed=$(knit_get_parameter "seed" "$@")

    local pi
    pi=$(_pi_monte_carlo "${samples}" "${seed}" "decimal")

    knit_output "pi" "${pi}"
    printf 'pi ~= %s  (%s samples, seed %s)\n' "${pi}" "${samples}" "${seed}"
    printf 'computed on host: %s\n' "$(hostname)"
}
knit_done

# -----------------------------------------------------------------------------
# Call the main entry point of the knit framework (must come last).
# -----------------------------------------------------------------------------
knit "$@"
