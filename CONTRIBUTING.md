# Contributing to Knit

Thank you for your interest in improving Knit. This guide explains how the
source is organized, the conventions the code follows, and what a change must
satisfy before it can merge.

## Project layout

`knit.sh` is a single-file framework, but that single file is an agglomeration
of multiple files in the `src/` folder. The Makefile concatenates those files
in a specific order. Each file in `src/` groups a single aspect of the
framework (for example logging, arguments, or the database).

Work happens in `src/`, never in the generated `knit.sh`.

### Make targets

```sh
make               # concatenate src/*.sh into knit.sh
make clean         # remove the generated knit.sh
```

Tests and static analysis:

```sh
make check              # check-unit + check-integration (the full suite)
make check-unit         # bats unit tests only (no Docker needed)
make check-integration  # integration tests on the cluster images (needs Docker)
make check-ai           # live AI tests against a local LLM (opt-in; see below)
make shellcheck         # ShellCheck static analysis of src/*.sh
```

Documentation:

```sh
make check-comments # every function and variable has a Doxygen comment block
make check-docs     # run every doc code example end to end and validate regions
make docs           # build the Sphinx website into docs/build/html
make web            # assemble the full public website into web/build/site
```

Coverage:

```sh
make coverage      # emit a knit.sh that sources src/*.sh, for kcov (CI use)
```

`make check` runs both the unit tests **and** the integration tests; the latter
build and run Docker cluster images, so day to day you will usually run
`make check-unit` and let CI run the integration suite. `make check-integration`
can be run locally, if your machine has Docker.

## Terminology

This terminology may be used in any documentation.

- **Knit developer** (or "developer"): person or agent developing `knit.sh` itself.
- **Knit user** (or "user"): person or agent using `knit.sh` to write an experiment.
- **Knit reproducer** (or "reproducer"): person or agent using a user's experiment.

## Coding conventions

Bash does not have a concept of private/public variables or functions, hence
the following conventions help ensure the code remains well decoupled into
modules.

### Function and variable names

- All function names should start with `knit_` or `_knit_`.
- All global variable names should start with `KNIT_` or `_KNIT_`.
- Variables and functions starting with one underscore should be considered
  **private**. They may be used within any file, but are not meant to be used by
  the end-user. There is no expectation of a stable API for these variables and
  functions.
- Variables and functions starting with no underscore are part of the public API.

A private function can be registered as a command:

```bash
knit_register my_command _knit_my_command
_knit_my_command() {
    ...
}
knit_done
```

Here the function is private, but the command itself may be public. Care should
be taken when modifying such functions so that the potentially public API of the
command is not changed.

### Documentation

Doxygen is used for documentation, with `.doxygen/doxygen-bash.sed` to parse the
Bash files and produce output that Doxygen accepts. The Doxygen XML output is
then used by Breathe to generate the API Reference section of the website.

Comment blocks should start and end with `# ----` (extend the line to 78 dash
characters). A comment block for a function should include `# @fn function()`.
Because of a limitation of `doxygen-bash.sed`, a variable must first be declared
with the `declare` keyword and then assigned on the next line (declaring and
assigning on the same line makes `doxygen-bash.sed` produce output that Doxygen
does not understand).

The prose documentation is a Sphinx website under `docs/`. **New user-facing
functionality must be documented there** — the tutorial, the relevant guide
pages, and, where a short recipe helps, the Stitch Guide (see the "Stitches"
notes in `CLAUDE.md`). Every code example in the docs is a tested snippet under
`docs/source/_code/`; `make check-docs` runs them, so keep the examples working
rather than hand-typing snippets into the pages.

### Declaration functions and the `@` shorthand

Every Knit **declaration** function (`knit_register*`, `knit_with_*`,
`knit_done`, …) has a terse `@` twin defined from a curated list in
`src/shorthand.sh`. The shorthand is described in the user documentation. When
you add or rename a declaration or decoration function, **update the mapping in
`src/shorthand.sh`** so the new function gains its `@` form. Runtime helpers
called inside a command body (`knit_get_parameter`, `knit_output`, the loggers,
…) deliberately have no shorthand and must not be added to that list.

## Contribution requirements

Before you open a pull request, make sure your change satisfies all of the
following:

- **All functions must be unit-tested.** Tests live in `tests/`, use
  [bats](https://bats-core.readthedocs.io/en/stable/), and are named
  `test_<module>.sh` after the `src/` module they exercise. A module is often
  split across several files with a suffix (for example `test_cli_*.sh`,
  `test_app_*.sh`); large files are split this way to keep each coverage run's
  memory in check.
- **Tests should ensure full coverage.**
- **`make check` must report no error** (`make check-unit` for the fast unit-only
  pass during development).
- **`make shellcheck` must pass** without errors or warnings. Knit uses
  ShellCheck for static analysis of the source. A `# shellcheck disable=code # reason`
  comment may be used to remove a warning when there is a good reason for it.
- **All functions and global variables** (regardless of scope) must be documented
  with Doxygen comment blocks; `make check-comments` verifies this.
- **New user-facing functionality must be documented** in the Sphinx site under
  `docs/`, with a working `make check-docs` example where code is shown.

### Live AI tests

The `ai` commands (`ai ask`, `ai query`) have fast, deterministic unit tests
that stub the network (`tests/test_ai*.sh`, run by `make check`). A separate
suite under `tests/ai/` exercises the same commands against a **real** LLM served
locally by [Ollama](https://ollama.com), to check the OpenAI-compatible
request/response and tool-calling contract end to end. These tests are opt-in and
are not part of `make check`.

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
