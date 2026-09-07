[![Tests](https://github.com/knit-sh/knit/actions/workflows/tests.yml/badge.svg)](https://github.com/knit-sh/knit/actions/workflows/tests.yml)
[![Integration](https://github.com/knit-sh/knit/actions/workflows/integration.yml/badge.svg)](https://github.com/knit-sh/knit/actions/workflows/integration.yml)
[![AI](https://github.com/knit-sh/knit/actions/workflows/ai.yml/badge.svg)](https://github.com/knit-sh/knit/actions/workflows/ai.yml)
[![ShellCheck](https://github.com/knit-sh/knit/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/knit-sh/knit/actions/workflows/shellcheck.yml)
[![Documentation Check](https://github.com/knit-sh/knit/actions/workflows/doccheck.yml/badge.svg)](https://github.com/knit-sh/knit/actions/workflows/doccheck.yml)
[![Code Coverage](https://github.com/knit-sh/knit/actions/workflows/codecov.yml/badge.svg)](https://github.com/knit-sh/knit/actions/workflows/codecov.yml)
[![codecov](https://codecov.io/gh/knit-sh/knit/branch/main/graph/badge.svg)](https://codecov.io/gh/knit-sh/knit)

<p align="center">
<img src="docs/source/_static/knit-logo-light.svg#gh-light-mode-only" />
<img src="docs/source/_static/knit-logo-dark.svg#gh-dark-mode-only" />
</p>

**Knit is a Bash framework for writing reproducible and portable HPC
(High-Performance Computing) experiments.** It turns an ordinary shell script
into a self-documenting CLI whose every run is recorded, so results can be
traced, repeated, and moved from a laptop to a supercomputer without changing
the code.

Full documentation lives at **[knit.sh](https://knit.sh)**.

## Why Knit

Computational experiments are hard to reproduce. The commands that produced a
result live in shell history, the software environment is rebuilt from memory,
and the same script has to be rewritten for each new machine and scheduler. Six
months later, nobody can say exactly how a number in a paper was produced.

Knit addresses this without asking you to leave the shell:

- **Simplicity.** Write experiments as plain Bash. Source `knit.sh`, register a
  function as a command, declare its typed parameters, and Knit gives you a
  complete CLI — `--help`, validation, and logging — for free.
- **Reproducibility.** Every invocation is recorded: its parameters, outputs,
  timing, and the environment it ran in. An experiment can be replayed and each
  result tied back to exactly how it was produced.
- **Portability.** The same experiment script runs unchanged on your laptop and
  on an HPC cluster. Knit detects the scheduler (Slurm, PBS, PALS, Flux) and the
  MPI launcher, so only the machine differs, never the code.
- **Provenance.** Knit records *how* each result came to be — which submission
  ran which job, which job launched which run, which setup built the software —
  as a queryable graph you can trace after the fact.

## A first taste

A Knit experiment is a normal script that sources `knit.sh`, registers commands,
and hands the command line to `knit`:

```bash
#!/bin/bash
source knit.sh

knit_set_program_description "A tiny experiment."

@command "greet" "Greet someone by name."
@with_required "name:string" "Who to greet."
@with_flag "capitalize" "Upper-case the whole greeting."
greet() {
    local name capitalize greeting
    name="$(knit_get_parameter "name" "$@")"
    capitalize="$(knit_get_parameter "capitalize" "$@")"
    greeting="Hello, ${name}!"
    [[ "${capitalize}" == "true" ]] && greeting="${greeting^^}"
    echo "${greeting}"
}
@done

knit "$@"
```

That is already a full CLI:

```console
$ ./exp.sh bootstrap                       # one-time: create .knit/ and its database
$ ./exp.sh greet --name Curie --capitalize
HELLO, CURIE!
$ ./exp.sh greet --help                    # generated from the declaration
```

Each command declares typed parameters (`integer`, `real`, `string`,
`boolean`, `uuid`), optional defaults, flags, and named outputs — and every run
is recorded in a small SQLite database under `.knit/`.

## What Knit gives you

- **A typed CLI from a Bash function** — required/optional parameters, flags,
  outputs, nested commands, and auto-generated `--help`, all from a few
  declarations. A concise `@` shorthand keeps experiments readable.
- **Automatic recording** — parameters, outputs, timing, job state, and
  allocated hosts land in a queryable SQLite database, with no bookkeeping code.
- **Reproducible software environments** — build a setup once (manual build,
  Spack environment, environment modules) and have dependent jobs re-hydrate it
  automatically.
- **Batch and parallel execution** — `submit` queues a job on the detected
  scheduler (or runs it locally); `run` launches an MPI application across a
  job's nodes with portable placement (procs, procs-per-node, binding).
- **Provenance you can query** — the links between setups, submissions, jobs,
  and runs form a graph you can query later to reconstruct how any result was
  produced.

## The experimental model

A Knit experiment moves through five stages, each recording what it did so a
later stage — and a later reader — can pick up exactly what an earlier one
produced:

- **Bootstrap** — install what Knit itself needs (e.g. `sqlite3`) into `.knit/`.
- **Setup** — build a reproducible software environment.
- **Submit** — queue a batch job on the scheduler, or run it locally.
- **Run** — launch a parallel (MPI) application across a job's nodes.
- **Aggregate** — read output from many jobs to produce publishable results.

The shape is a *fan-out* from bootstrap to run (one bootstrap, many setups, each
used by many jobs, each running many applications) and a *fan-in* to aggregate.

## Getting started

Knit is a single `knit.sh` file. Download its latest release, drop it next to
your experiment script, `source` it, and you are ready to go.

- The **[Quickstart](https://knit.sh/docs/quickstart.html)** writes and runs a
  one-command experiment in a few minutes.
- The **[Tutorial](https://knit.sh/docs/tutorial/index.html)** grows a single
  real experiment from a plain command into a Spack-backed, MPI-parallel,
  recorded workload.

## Authors

Knit is develop by the following people.

- [Matthieu Dorier](https://mdorier.github.io/) ([@mdorier](https://github.com/mdorier)), Argonne National Laboratory

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the source
layout, coding conventions, and what a change must satisfy before it can merge.

## License

Knit is released under the [MIT License](LICENSE).
