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

Knit is a framework to help write reproducible and portable HPC experiments

# Contributing

knit.sh is a single-file framework but this single file is agglomeration of
multiple files located in the src/ folder. The Makefile concatenates the files
in a specific order. Individual files in src/ each aim to group a single aspect
of the framework (e.g. logging, arguments, database, etc.).

## Terminology

This terminology may be used in any documentation.

- Knit developer (or "developer"): person or agent developing knit.sh tself.
- Knit user (or "user"): person or agent using knit.sh to write an experiment.
- Knit reproducer (or "reproducer"): person or agent using a user's experiment.

## Declaration shorthand (`@`)

Every Knit **declaration** function has a terse, decorator-style twin: `knit_x`
gains an `@x`. The register family is remapped — `knit_register` becomes
`@command`, and each `knit_register_<x>` becomes `@<x>` (so `knit_register_setup`
is `@setup`, `knit_register_job` is `@job`, and so on). The shorthand is enabled
by default and is what the Quickstart, the tutorial, and the `examples/` scripts
use. It is **additive**: the `knit_*` functions are unchanged and remain the
canonical, stable API.

A job written the long way:

```bash
knit_register_job "my_job" my_func "A job."
knit_with_required "x:integer" "The x value."
my_func() { ...; }
knit_done
```

reads, with the shorthand:

```bash
@job "my_job" "A job."
@with_required "x:integer" "The x value."
my_func() { ...; }
@done
```

**Only declaration and decoration functions get a shorthand.** Functions called
at runtime inside a command body — `knit_get_parameter`, `knit_output`,
`knit_artifact`, `knit_job_hostnames`, the loggers, … — and the `knit` entry
point itself have **no** `@` twin. The set is a curated list in
`src/shorthand.sh`.

**Name discovery.** The five registration shorthands — `@command`, `@app`,
`@job`, `@setup`, and `@wrapper` — do **not** take a function-name argument. Each
reads its own call site and walks forward to the next function definition, using
that function as the command's body. Blank lines, comments, and intervening
`@with_*` decorators are skipped, so the decorators sit directly above the
function they describe. (The bodyless `@resource` is a plain pass-through and
keeps its `<type> <description>` signature.)

**Grouping commands: `@empty`.** A namespace or grouping command has no body.
Where the long form passes `knit_empty` as the body, the shorthand places an
explicit `@empty` marker between the declaration and `@done`:

```bash
@command "metadata" "Access metadata about the experiment."
@empty
@done
```

**Opting out.** Set `KNIT_WITHOUT_SHORTHAND` before sourcing `knit.sh` to a
comma-separated list of tokens (the part after `@`), or `all`:

```bash
KNIT_WITHOUT_SHORTHAND="with_required,job"   # these two @ functions not defined
KNIT_WITHOUT_SHORTHAND="all"                 # no @ shorthand at all
source knit.sh
```

An opted-out `@` function is simply not defined; the `knit_*` long form is always
available. An unrecognized token produces a warning and is ignored. Opting out of
`empty` while using `@command`/`@job`/… for a bodyless grouping command is
unsupported — the extractor needs the `@empty` marker, so such a command must use
the long form.

Name discovery reads the experiment from its source file, so the shorthand cannot
be used when the experiment is not a readable file — piped (`curl … | bash`), a
process substitution, or `eval`'d. In that case use the long `knit_register*`
form with an explicit function name.

## Coding conventions

Bash does not have a concept of private/public variables or functions, hence
the following conventions help ensure the code remains well decoupled into
modules.

### Functions and variable names

- All the function names should start with `knit_` or `_knit_`.
- All the global variable names should start with `KNIT_` or `_KNIT_`.
- Variables and functions starting with one underscore should be considered
  **private**, they may be used within any file, but are not meant to be used by
  the end-user. There is no expectation of stable API for these variables and
  functions. (Whether a private symbol will be needed across files is hard to
  predict, so a single underscore is used for all of them regardless of current
  usage.)
- Variables and functions starting with no underscore are part of the public API.

Note that a private function can be registered as a command, e.g.:

```
knit_register my_command _knit_my_command
_knit_my_command() {
    ...
}
knit_done
```

In this case while the function is private, the command itself may be public.
Care should be taken when modifying such functions so that the potentially
public API of the command is not changed.

### Command names

Commands are functions that are registered using the various `knit_register_*`
functions. They can be invoked by the user from a terminate
(e.g. `./my_exp.sh my_command ...`) or from within the experiment file
(e.g. `knit my_command ...`).

Unless otherwise specified/documented, any invokation of a command will be
recorded in the database.

Command names should start with a letter, number, or underscore, followed by
any sequence of letters, numbers, underscores, and hyphens. Note that hyphens
may be internally replaced with underscores when necessary, so defining two
commands that differ by an hyphen/underscore (e.g. "my_command" and "my-command")
should be avoided. We recommend using hyphens.

Commands will be listed in the CLI, unless marked with `knit_hidden`.

Commands with a name starting with an underscore will automatically be marked
as hidden and will not be considered part of the public API of the experiment.

Knit developers may use names starting with two underscores to define commands
that are private to the framework (e.g. commands used as part of other commands
to record something in the database). Users may use commands starting with a
single underscore to define commands that are private to the experiment and not
meant to be called by Knit reproducers.

### Documentation

Doxygen is used for documentation, using .doxygen/doxygen-bash.sed to parse the
bash files and produce an output that Doxygen is happy with.

Comment blocks should start and end with `# ----` (extend the line to 78
characters). Comment blocks for function should include `# @fn function()`.
Due to limitations of doxygen-bash.sed, variable should be first declared
with a `declare` keyword, then assigned to on the next line (declaring and
assigning in the same line makes doxygen-bash.sed produce an output that
doxygen does not understand).

## Contribution requirements

- All the functions should be unit-tested. The tests directory contains test
  files in the form "test_<name>.sh" where "<name>" is the name of the file
  from src/ that we are testing. The tests use
  [bats](https://bats-core.readthedocs.io/en/stable/).
- Tests should ensure full coverage.
- `make check` should report no error.
- Knit uses shellcheck to perform static analysis of the source.
  `make shellcheck` should pass without errors or warning.
- `# shellcheck disable=code # reason` may be used to remove a warning
  if there is a good reason for it.
- All the functions and global variables (regardless of scope) should be
  documented using Doxygen syntax.

### Live AI tests

The `ai` commands (`ai ask`, `ai query`) have fast, deterministic unit
tests that stub the network (`tests/test_ai*.sh`, run by `make check`). A separate
suite under `tests/ai/` exercises the same commands against a **real** LLM served
locally by [Ollama](https://ollama.com), to check the OpenAI-compatible
request/response and tool-calling contract end to end. These are opt-in and are
not part of `make check`.

To run them locally, install Ollama, pull the model, then:

```sh
ollama serve &
ollama pull qwen2.5:7b-instruct-q4_K_M
export KNIT_AI_LIVE=1 OLLAMA_API_KEY=ollama
make check-ai
```

Without `KNIT_AI_LIVE=1` (or if no server is reachable) every test skips cleanly.
The model, endpoint, and API-key env var can be overridden with `KNIT_AI_MODEL`,
`KNIT_AI_BASE_URL`, and `OLLAMA_API_KEY`. CI runs this suite via the `ai`
workflow; because a live model is nondeterministic, that check is informational
and is not required for merges.
