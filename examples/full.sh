#!/usr/bin/env bash
#
# =============================================================================
#  knit — a guided tour (examples/full.sh)
# =============================================================================
#
# This is a complete, runnable knit experiment. It estimates the value of pi
# with a Monte-Carlo method, and along the way it exercises every feature knit
# currently implements: bootstrapping, machine profiles, metadata, typed
# command parameters, setups (reproducible environments, optionally backed by a
# Spack environment), job submission to a batch scheduler (Slurm/PBS) — or to
# local background processes when no scheduler is present — MPI application
# launch across a job's allocation with `knit run`, the Spack package
# manager (`knit spack`, plus Spack-backed setups), call-site aliasing of
# provenance edges with `knit_as`, querying the database and its provenance
# graph with `knit query` (read-only SQL, a schema catalog, and Cypher over the
# recorded provenance), commands that are usable before bootstrap
# (`knit_usable_before_bootstrap`), a machine- and human-readable description of
# the whole interface with `knit describe`, and natural-language access to the
# experiment and its recorded runs with `knit ai` (read-only; needs an
# OpenAI-compatible provider).
#
# HOW TO USE THIS FILE
# --------------------
# Read the numbered walkthrough below and run the commands one at a time from
# the directory that contains this script and knit.sh. Each step explains what
# the command does and what you should expect to see. The same script runs
# unchanged on your laptop (local backend) and on an HPC login node (Slurm/PBS)
# — that portability is the whole point of knit.
#
# Prerequisites: bash, make, and curl/wget. Bootstrap prefers a system
# sqlite3/jq when present (it symlinks them into ./.knit); only when they are
# missing does it build sqlite from source and download jq, which additionally
# needs a C compiler. Pass --ignore-system-sqlite / --ignore-system-jq to force
# the from-source/download path even when a system binary exists. Everything
# knit installs lives under ./.knit and is removed with `rm -rf .knit`.
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
# Prints the program description and the list of subcommands: preflight,
# estimate, submit, run, setup, bootstrap, metadata, profile, job, db, query,
# spack, ai.
# Every command takes --help,
# e.g.
#
#   ./full.sh estimate --help
#   ./full.sh submit --help
#   ./full.sh run --help
#
# The per-command help lists each parameter, its type, whether it is
# required/optional (with the default), and its description.
#
# Jobs, setups, and apps are invoked through `submit`/`setup`/`run` after a `--`,
# and you can ask for their help by name, e.g.
#
#   ./full.sh submit montecarlo --help
#   ./full.sh setup mcenv --help
#   ./full.sh run mcrank --help
#
# The usage line reflects the real grammar
# (`submit [OPTIONS] -- montecarlo [OPTIONS]`), and the help shows the
# job/setup/app's own options, the enclosing `submit`/`setup`/`run` options (such
# as `--setup` / `--path` / `--procs`), and — for any command declared with
# `knit_with_setup` — the setup type it requires. (`knit_with_setup` works on any
# command now, not just jobs; a non-job command gains its own `--setup` option.)
#
# Most commands only make sense once the experiment is bootstrapped (they need
# the database and binaries that `bootstrap` provisions under ./.knit). A few are
# meaningful *before* bootstrap and are declared `knit_usable_before_bootstrap`:
# `bootstrap` itself, `describe`, `profile`, and — in this experiment — the
# `preflight` command below. On a fresh checkout `./full.sh --help` lists only
# those usable commands; running a not-usable one first is refused with a uniform
# "requires bootstrap" message instead of a confusing failure deep inside:
#
#   ./full.sh preflight            # runs before bootstrap: checks prerequisites
#   ./full.sh estimate --samples 1000   # refused: "requires bootstrap"
#
# After bootstrap, `--help` lists everything and all commands run normally.
#
# -----------------------------------------------------------------------------
# 2. Bootstrap the experiment
# -----------------------------------------------------------------------------
#   ./full.sh bootstrap --project pi-demo
#
# This creates ./.knit, makes sqlite and jq available (symlinking the system
# binaries when present, otherwise building sqlite from source and downloading
# jq — a minute or two the first time), creates the ./.knit/knit.db database,
# and records some metadata. Because this experiment declares a Spack-backed
# setup (`mclib`, step 11), bootstrap also provisions a knit-private Spack — a
# tarball download (via curl+tar, no git needed) that adds a few minutes the
# first time. knit
# auto-detects the batch scheduler; on a machine without one it falls back to
# local execution and warns you. You can be explicit:
#
#   ./full.sh bootstrap --project pi-demo --scheduler local
#   ./full.sh bootstrap --project pi-demo --scheduler slurm --account MYALLOC
#
# If you run on a self-managed cluster with no batch scheduler, use --scheduler
# none and point it at a file listing your nodes (one host per line). Jobs then
# run locally, but knit_job_hostnames reports that node list as the allocation:
#
#   ./full.sh bootstrap --project pi-demo --scheduler none --default-nodefile ~/nodes.txt
#
# To force the from-source/download path even when a system sqlite3/jq exists:
#
#   ./full.sh bootstrap --project pi-demo --ignore-system-sqlite --ignore-system-jq
#
# Spack is provisioned automatically here (the experiment needs it). To pin a
# specific Spack version instead of the latest release, pass it to --spack (see
# step 11):
#
#   ./full.sh bootstrap --project pi-demo --spack v0.22.0
#
# If your machine has a built-in profile (see step 3), pass it to prepopulate
# the scheduler, launcher, queue, walltime cap and per-node core count:
#
#   ./full.sh bootstrap --project pi-demo --profile polaris
#
# You can also configure the AI provider here with the --ai-* options (see step
# 13); e.g. --ai-api-key-env OPENAI_API_KEY --ai-model gpt-4o-mini.
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
# `knit query` (section 14) adds higher-level querying on top of `db query`:
# read-only SQL, a schema catalog, and Cypher queries over the provenance graph.
# Producing plots from the database is still future work.
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
#   cat env/jobs/$uuid/.stdout    # the job's output (pi estimate + host list)
#   cat env/jobs/$uuid/.job.sh    # the generated batch script
#   cat env/jobs/$uuid/.job.id    # the scheduler's job id (or local PID)
#
# Every submission is tracked in the `jobs` table, and its lifecycle
# state advances submitted -> running -> completed (or -> killed if cancelled).
# The `hostnames` column records the nodes each job actually ran on (the
# deduplicated list, comma-separated), filled in automatically when the job
# starts — no experiment code required. The `native_cmd` column records the exact
# scheduler command knit issued to submit the job (e.g. `sbatch .../.job.sh`),
# also logged at trace level just before it runs:
#
#   ./full.sh db query --from jobs \
#       --select "id, job, state, hostnames, native_cmd" --header --column
#
# The job's own output (pi) is recorded in its own table, named after the job:
#
#   ./full.sh db query --from montecarlo \
#       --select "id, samples, seed, pi" --header --column
#
# -----------------------------------------------------------------------------
# 9. Inspect jobs
# -----------------------------------------------------------------------------
# The `job` commands read the tracking above without writing raw SQL. List every
# job (optionally filtered by state or setup), then drill into one by UUID:
#
#   ./full.sh job list                       # id, job, state for all jobs
#   ./full.sh job list --status running      # only running jobs
#   ./full.sh job list --setup ./env         # only jobs of this setup
#   ./full.sh job list --no-setup            # only setup-less jobs
#   ./full.sh job list --types montecarlo    # only jobs of these (comma-sep) types
#   ./full.sh job list --json                # same listing as a JSON array
#
#   ./full.sh job status --id $uuid          # just the lifecycle state
#   ./full.sh job wait   --id $uuid          # block until terminal (non-zero if killed)
#   ./full.sh job cancel --id $uuid          # stop a running job (marks it killed)
#   ./full.sh job rm     --id $uuid          # delete a job's dir + row (--force if live)
#   ./full.sh job resubmit --id $uuid        # re-run reusing the recorded parameters
#
# `job show` combines both tables for one job: its submission options and, once
# it has run, the parameters it recorded. Add --json for machine-readable output:
#
#   ./full.sh job show --id $uuid            # Submission: + Parameters: sections
#   ./full.sh job show --id $uuid --json
#
# And read a job's captured output straight from its working directory:
#
#   ./full.sh job show stdout --id $uuid     # the job's standard output
#   ./full.sh job show stderr --id $uuid     # the job's standard error
#   ./full.sh job show script --id $uuid     # the generated batch script
#
# Add --follow to stdout/stderr to stream a running job's output live (like
# tail -f); it stops on its own once the job finishes:
#
#   ./full.sh job show stdout --id $uuid --follow
#
# -----------------------------------------------------------------------------
# 10. Launch an MPI application inside a job (knit run)
# -----------------------------------------------------------------------------
#   ./full.sh submit --setup ./env --wait -- mcparallel --procs 1
#
# `mcparallel` is a job whose body calls `knit run` to launch the `mcrank` app.
# `knit run` starts one process ("rank") per slot of the job's allocation, sets
# KNIT_MPI_RANK / KNIT_MPI_SIZE / KNIT_MPI_LOCAL_RANK for each rank, and forwards
# the job's environment (including the activated setup) to every rank. Each
# mcrank rank estimates pi on its own slice of the samples and prints the host it
# landed on; knit records the run once, from rank 0.
#
# `knit run` is always called from inside a job — the job supplies the node
# allocation the launcher places ranks on. Here mcparallel forwards its --procs
# option straight to `knit run`:
#
#   knit run --procs <N> -- mcrank
#
# --procs defaults to 1 so this runs anywhere, including a laptop with no MPI
# launcher. Launching more than one rank needs a real MPI launcher: knit
# auto-detects OpenMPI and MPICH; without one it uses the built-in "none"
# launcher, which runs a single local rank and rejects --procs > 1. On a cluster,
# submit with more nodes and a higher --procs to spread ranks across the
# allocation:
#
#   ./full.sh submit --setup ./env --nodes 2 --wait -- mcparallel --procs 8
#
# The placement is controlled by `knit run`'s options — see their help:
#
#   ./full.sh run --help          # the run dispatcher and its placement options
#   ./full.sh run mcrank --help   # the app's own options, plus the run options
#
# `run [OPTIONS] -- <app> [OPTIONS]`: --procs, --procs-per-node, --hostnames (a
# comma-separated subset of the allocation, e.g. from
# `knit_job_hostnames --separator , --select 0:2`), the per-rank resource knobs
# --cpus-per-proc, --bind (none/core/socket/numa/thread), --gpus-per-proc and
# --gpu-bind (each translated per launcher, best-effort — a backend with no native
# flag warns and skips), --launcher (force a backend: none, openmpi, mpich, slurm,
# pbs, pals), and --launcher-args (raw passthrough for anything not normalized).
#
# Every run is recorded in the `runs` table (the app, the resolved procs and
# hostnames, the parent job's UUID, and `native_cmd` — the exact launcher command
# knit issued, also logged at trace level before it runs), and rank 0's output in
# the app's own table (`mcrank`):
#
#   ./full.sh db query --from runs \
#       --select "id, app, job, procs, hostnames, native_cmd" --header --column
#   ./full.sh db query --from mcrank \
#       --select "id, samples, seed, pi" --header --column
#
# -----------------------------------------------------------------------------
# 11. Reproducible environments with Spack
# -----------------------------------------------------------------------------
# When an experiment needs specific libraries, knit can manage a private Spack
# for you, build the exact packages it needs, and record them for reproduction.
# This file registers a Spack-backed setup called `mclib`, so `bootstrap` (step
# 2) already provisioned a knit-private Spack under ./.knit — a tarball download
# (curl+tar, no git needed) that takes a few minutes the first time.
#
# You can pin the Spack version at bootstrap with --spack (bare = latest
# release); pass a tag/branch/commit to pin a specific one (and likewise for the
# package repo), e.g. `--spack v0.22.0 --spack-packages v0.22.0`. The resolved
# refs and commits are stored as metadata for provenance.
#
# `knit spack` forwards straight to the private Spack. It is a thin wrapper, so
# every spack subcommand and flag works unchanged (including --help), and each
# call is recorded in the DB:
#
#   ./full.sh spack find
#   ./full.sh spack info zlib
#   ./full.sh spack --help
#
# Better still, a setup can DECLARE the environment it needs and let knit build
# it. Build the `mclib` setup:
#
#   ./full.sh setup --path ./libenv -- mclib
#
# `mclib` is declared with `knit_with_spack_specs "zlib"`: knit writes a minimal
# spack.yaml, builds and installs that environment as the setup's FIRST step,
# then activates it so the rest of the setup body sees the packages. The concrete
# spack.yaml and spack.lock are captured into the setup's DB row as provenance:
#
#   ./full.sh db query --from "setup:mclib" \
#       --select "id, __spack_yaml__, __spack_lock__" --header --column
#
# The activation is baked into libenv/.activate.sh (a `spack env activate` block),
# so any job that requires this setup (declared with `knit_with_setup "mclib"`)
# re-hydrates the Spack environment automatically — exactly like the
# montecarlo/mcenv flow in steps 7–8, but with Spack-provided packages on the
# path. For a manifest you maintain by hand, pass a file (or feed one on stdin)
# to `knit_with_spack_env` instead of using the `knit_with_spack_specs` sugar.
#
# -----------------------------------------------------------------------------
# 12. Describe the whole experiment
# -----------------------------------------------------------------------------
# `--help` documents one command at a time; `describe` dumps the entire
# interface — every command (builtin or user-declared), its parameters, types,
# defaults, constraints, and outputs — in one shot, in whichever format you ask
# for:
#
#   ./full.sh describe                       # human-readable (colored on a TTY)
#   ./full.sh describe --format json         # machine-readable JSON
#   ./full.sh describe --format json --compact  # the same JSON on one line
#   ./full.sh describe --format yaml         # the same model, YAML
#   ./full.sh describe --format markdown     # a COMMANDS.md-style document
#
# It reads the registration tables only (no bootstrap or database needed), so it
# works on a fresh checkout. Narrow, prune, and redirect it as you like:
#
#   ./full.sh describe --exclude-builtins    # only your own commands
#   ./full.sh describe --only "submit,estimate" --recursive
#   ./full.sh describe --no-output-params --no-input-params
#   ./full.sh describe --include-implementation --only estimate
#   ./full.sh describe --format markdown --exclude-builtins --output COMMANDS.md
#
# `--include-implementation` appends each user command's function body (builtin
# bodies are never shown); `--output <file>` writes the description to a file
# instead of stdout (and disables color for the default format).
#
# -----------------------------------------------------------------------------
# 13. Ask questions in natural language (knit ai)
# -----------------------------------------------------------------------------
# knit can put an LLM in front of your experiment: it answers questions about
# the interface and the recorded runs by calling knit's own commands. Everything
# the AI can do is READ-ONLY — the tools it may call (describe, help, metadata
# show, db query, job show) never modify anything, and any SQL it generates is
# checked and rejected unless it is a read-only statement.
#
# First point knit at an OpenAI-compatible provider. knit never stores your API
# key: you give it the NAME of the environment variable that holds the key, and
# it reads that variable at call time.
#
#   export OPENAI_API_KEY=sk-...
#   ./full.sh ai init --api-key-env OPENAI_API_KEY --model gpt-4o-mini
#
# The same thing can be configured at bootstrap with the --ai-* options:
#
#   ./full.sh bootstrap --project pi-demo \
#       --ai-api-key-env OPENAI_API_KEY --ai-model gpt-4o-mini
#
# --base-url defaults to https://api.openai.com/v1; point it at any
# OpenAI-compatible endpoint. If you would rather keep the base URL or model out
# of the database too, store their env-var names instead (--base-url-env /
# --model-env). Use --force to overwrite an existing configuration.
#
# `ai ask` answers open-ended questions, calling the read-only tools as needed:
#
#   ./full.sh ai ask --question "which commands submit a job?"
#   ./full.sh ai ask --question "how many montecarlo jobs completed?"
#   ./full.sh ai ask --question "..." --verbose   # stream tool calls to stderr
#
# `ai query` is narrower and easy to audit: it turns a question into a SINGLE
# read-only SQL statement, runs it against ./.knit/knit.db, and prints the result
# in the sqlite output mode you pick. If the SQL errors, knit feeds the error
# back so the model can correct it (up to --max-iterations):
#
#   ./full.sh ai query --question "list completed jobs and their hostnames"
#   ./full.sh ai query --question "count runs per app" --format csv
#   ./full.sh ai query --question "..." --sql-only   # print the SQL, don't run it
#
# Both commands need a configured provider and a reachable API key; without one
# they stop with a clear message pointing you back to `ai init`.
#
# -----------------------------------------------------------------------------
# 14. Provenance and querying (knit_as + knit query)
# -----------------------------------------------------------------------------
# Everything knit records is also a node in a provenance graph. When a command's
# body invokes another command, knit records a "call" edge between them; a job
# submitted with --setup records a "used_by" edge from the setup to the job. The
# steps above have already built such a graph (every submit --setup ... added a
# used_by edge). `knit query` lets you read both the tables and that graph.
#
# `knit_as` labels a call edge, so repeated invocations of the same command can
# be told apart later. The `sweep` job below runs `estimate` twice under the
# aliases "coarse" and "fine":
#
#   knit_as coarse estimate --samples 1000
#   knit_as fine   estimate --samples 100000
#
# Submit it (it requires the mcenv setup, so a used_by edge is recorded too),
# then query the results three ways:
#
#   ./full.sh submit --setup ./env --wait -- sweep
#
# `knit query catalog` introspects the live database schema. A table owned by a
# command is annotated with that command (e.g. the `jobs` table is owned by
# `submit`):
#
#   ./full.sh query catalog                  # every table and its columns
#   ./full.sh query catalog -- jobs          # just the jobs table
#
# `knit query sql` runs a read-only SQL statement through knit's own sqlite (any
# write is rejected). It is the scriptable sibling of `db query` from step 6:
#
#   ./full.sh query sql --exec \
#       "SELECT id, samples, pi FROM estimate ORDER BY samples" --header --column
#
# `knit query graph` runs a Cypher query over the provenance graph, powered by
# knit-graph (bootstrap built it under ./.knit). A node's label may be written as
# either the table name or the owning command name — knit passes the live map to
# knit-graph — and each edge carries its type ("call"/"used_by") and any knit_as
# alias. Cross the submit->job call edge (the `submit` command owns the `jobs`
# table) to read the job name:
#
#   ./full.sh query graph --exec \
#       "MATCH (j:submit)-[:call]->(s:sweep) RETURN j.job"
#
# tell the two aliased estimate calls apart (inline and WHERE spellings both
# work):
#
#   ./full.sh query graph --exec \
#       "MATCH (s:sweep)-[{alias:'fine'}]->(e:estimate) RETURN e.samples"
#   ./full.sh query graph --exec \
#       "MATCH (s:sweep)-[e]->(x:estimate) WHERE e.alias = 'coarse' RETURN x.samples"
#
# or follow the used_by edge back to the setup a job consumed (label the setup
# with its `setup:<name>` table; the job endpoint is named but not projected):
#
#   ./full.sh query graph --exec \
#       "MATCH (env:\`setup:mcenv\`)-[:used_by]->(s:sweep) RETURN env.id"
#
# Both `sql` and `graph` share --format (list/json/csv/box/markdown/...),
# --header and --separator; `graph` also takes --explain / --ast to inspect the
# SQL knit-graph generates for a query. `knit query` only ever reads, so it is
# safe to run at any time after bootstrap.
#
# -----------------------------------------------------------------------------
# 15. Clean up
# -----------------------------------------------------------------------------
#   rm -rf .knit env libenv
#
# Removes knit's private tooling, the database, and the setup/job directories.
#
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
# preflight — a command that is usable *before* bootstrap.
#
# Declared with knit_usable_before_bootstrap, so it appears in `--help` and runs
# on a fresh checkout (before ./.knit exists). Such commands must not declare a
# table or use --when: both would silently do nothing before bootstrap. This one
# just reports whether the host has the tools bootstrap needs.
# -----------------------------------------------------------------------------
knit_register preflight "preflight" "Check this machine has what bootstrap needs (usable before bootstrap)."
knit_usable_before_bootstrap
preflight() {
    local ok=0 tool
    for tool in cc curl tar; do
        if command -v "${tool}" >/dev/null 2>&1; then
            printf '  %-6s found\n' "${tool}"
        else
            printf '  %-6s MISSING\n' "${tool}"
            ok=1
        fi
    done
    if [[ "${ok}" -eq 0 ]]; then
        printf 'All prerequisites present — ready to bootstrap.\n'
    else
        printf 'Some prerequisites are missing (see above).\n'
    fi
    return "${ok}"
}
knit_done

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
#
# The body calls knit_job_hostnames to report the node(s) the scheduler gave the
# job (deduplicated by default; also supports --json and --raw for a per-slot
# hostfile suitable for an MPI launcher).
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
    # knit_job_hostnames reports the nodes the scheduler allocated to this job
    # (deduplicated by default; also supports --json and --raw).
    printf 'ran on hosts: %s\n' "$(knit_job_hostnames --separator ', ')"
}
knit_done

# -----------------------------------------------------------------------------
# mcrank — an app: one MPI rank of a parallel Monte-Carlo pi estimate.
#
# Apps are launched by `knit run`, which starts one copy per rank and sets
# KNIT_MPI_RANK / KNIT_MPI_SIZE / KNIT_MPI_LOCAL_RANK for each (a single, no-MPI
# run gets rank 0 of size 1). This app reads those variables to take its own
# 1/size slice of the samples, with a rank-offset seed so the slices are
# independent yet reproducible, and prints its partial estimate and the host it
# ran on. knit records outputs only from rank 0, so knit_output here stores rank
# 0's partial.
#
# An app has no setup of its own: it inherits the environment of the surrounding
# job. --samples/--seed therefore default to the MC_SAMPLES/MC_SEED exported by
# the job's `mcenv` setup, exactly as the montecarlo job's do.
#
# A true global estimate would average the ranks' partials with an MPI reduction;
# that is outside knit's scope (the launcher runs independent processes), so this
# example simply reports each rank on its own.
# -----------------------------------------------------------------------------
knit_register_app "mcrank" _mcrank_app "One rank of a parallel Monte-Carlo pi estimate."
knit_with_optional "samples:integer" "ENV[MC_SAMPLES]" "Total samples across all ranks (default: MC_SAMPLES)."
knit_with_optional "seed:integer"    "ENV[MC_SEED]"    "Base PRNG seed (default: MC_SEED)."
knit_with_output   "pi:real" "0"                       "Rank 0's partial pi estimate."
_mcrank_app() {
    local samples seed
    samples=$(knit_get_parameter "samples" "$@")
    seed=$(knit_get_parameter "seed" "$@")

    # KNIT_MPI_* are set by knit for every rank (single, no-MPI run => 0/1/0).
    local rank="${KNIT_MPI_RANK}" size="${KNIT_MPI_SIZE}"

    # This rank's slice of the work: split the samples as evenly as possible,
    # giving any remainder to rank 0. A rank-offset seed keeps the slices
    # independent but reproducible.
    local my_samples=$(( samples / size ))
    (( rank == 0 )) && my_samples=$(( my_samples + samples % size ))
    local my_seed=$(( seed + rank ))

    local pi
    pi=$(_pi_monte_carlo "${my_samples}" "${my_seed}" "decimal")

    printf 'rank %s/%s on %s: pi ~= %s  (%s samples, seed %s)\n' \
        "${rank}" "${size}" "$(hostname)" "${pi}" "${my_samples}" "${my_seed}"

    # Only rank 0 records (knit suppresses recording on the other ranks); store
    # its partial as the run's recorded estimate.
    knit_output "pi" "${pi}"
}
knit_done

# -----------------------------------------------------------------------------
# mcparallel — a job: estimate pi in parallel by launching mcrank with knit run.
#
# `knit run` must be called from inside a job (the job supplies the node
# allocation the launcher places ranks on). This body forwards its --procs option
# to `knit run`; --procs defaults to 1 so the job runs anywhere, including a
# laptop with no MPI launcher. On a real cluster, submit with more nodes and a
# higher --procs to spread ranks across the allocation.
# -----------------------------------------------------------------------------
knit_register_job "mcparallel" _mcparallel_job "Estimate pi in parallel via knit run."
knit_with_setup    "mcenv"                                  # requires an `mcenv` setup
knit_with_optional "procs:integer" "1" "MPI ranks to launch (needs OpenMPI/MPICH for > 1)."
_mcparallel_job() {
    local procs
    procs=$(knit_get_parameter "procs" "$@")

    # Launch one mcrank per rank across the job's allocation. --samples/--seed are
    # omitted, so each rank fills them from the setup environment it inherits
    # (MC_SAMPLES / MC_SEED).
    knit run --procs "${procs}" -- mcrank
}
knit_done

# -----------------------------------------------------------------------------
# sweep — a job that runs `estimate` twice, labelling each call with knit_as.
#
# When a command's body invokes another command, knit records a provenance
# "call" edge between them. knit_as labels that edge so repeated invocations can
# be told apart in `knit query graph` (guided-tour section 14). Here the two
# estimate calls are aliased "coarse" and "fine"; each also records its own row
# in the `estimate` table.
# -----------------------------------------------------------------------------
knit_register_job "sweep" _sweep_job "Run a coarse and a fine estimate (aliased for provenance)."
knit_with_setup    "mcenv"                             # requires an `mcenv` setup
_sweep_job() {
    knit_as coarse estimate --samples 1000
    knit_as fine   estimate --samples 100000
}
knit_done

# -----------------------------------------------------------------------------
# mclib — a Spack-backed setup (see guided-tour section 11).
#
# knit_with_spack_specs declares a minimal Spack environment (here just "zlib", a
# tiny, quick-to-build package). knit builds and activates it as the setup's
# first step, and captures the concrete spack.yaml / spack.lock as DB provenance.
# Any job that requires this setup inherits the activated environment.
#
# Because this experiment declares a Spack environment, `bootstrap` provisions
# the knit-private Spack automatically (downloaded via curl+tar, no git needed),
# even without --spack.
# -----------------------------------------------------------------------------
knit_register_setup "mclib" _mclib_setup "Build a Spack environment (zlib)."
knit_with_spack_specs "zlib"
_mclib_setup() {
    # The Spack environment is already built and activated here, so packages
    # from the specs are on PATH / LD_LIBRARY_PATH. Anything exported is
    # captured into .activate.sh (next to the Spack re-activation block) and
    # inherited by dependent jobs.
    export MC_LIB="zlib"
}
knit_done

# -----------------------------------------------------------------------------
# Call the main entry point of the knit framework (must come last).
# -----------------------------------------------------------------------------
knit "$@"
