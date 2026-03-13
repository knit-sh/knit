# knit

[![Tests](https://github.com/knit-sh/knit/actions/workflows/tests.yml/badge.svg)](https://github.com/knit-sh/knit/actions/workflows/tests.yml)
[![ShellCheck](https://github.com/knit-sh/knit/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/knit-sh/knit/actions/workflows/shellcheck.yml)
[![Documentation Check](https://github.com/knit-sh/knit/actions/workflows/doccheck.yml/badge.svg)](https://github.com/knit-sh/knit/actions/workflows/doccheck.yml)
[![Code Coverage](https://github.com/knit-sh/knit/actions/workflows/codecov.yml/badge.svg)](https://github.com/knit-sh/knit/actions/workflows/codecov.yml)
[![codecov](https://codecov.io/gh/knit-sh/knit/branch/main/graph/badge.svg)](https://codecov.io/gh/knit-sh/knit)

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

## Coding conventions

Bash does not have a concept of private/public variables or functions, hence
the following conventions help ensure the code remains well decoupled into
modules.

### Functions and variable names

- All the function names should start with `knit_`, `_knit_`, or `__knit_`.
- All the global variable names should start with `KNIT_`, `_KNIT_`, or `__KNIT_`.
- Variables and functions starting with two underscores should be considered
  **private** and used only in the file in which they are defined. There is no
  expectation of stable API for these variables and functions.
- Variables and functions starting with one underscore should be considered
  **internal**, they can be used within any other file, but are not meant to be
  used by the end-user. There is no expectation of stable API for these variables
  and functions.
- Variables and functions starting with no underscore are part of the public API.

Note that a private function can be registered as a command, e.g.:

```
knit_register my_command __knit_my_command
__knit_my_command() {
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
