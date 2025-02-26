# Tutorial

In this document, we will run through how to use Knit to make an experiment
reproducible. For this, we will use [this repository]() as the HPC code to
run. This code is a simple [Game of Life]() simulation written in C and
parallelized using MPI. Once built and installed as explained in its
[README]() file, it can be run as follows.

```bash
$ game-of-life <s> <p> <i>
```

Where `s` is the size of the grid (the grid will be a square of `s` by `s`),
`p` is the initial probability (between 0 and 1) for any cell to be alive,
and `i` is the number of iterations.

When executed, this code will run `i` iterations from an initially random
grid, and print the number of cells alive at the end.

The code can be run with MPI as follows.

```bash
$ mpiexec ... game-of-life <s> <p> <i>
```

The number of processes used should be a square number (e.g., 1, 4, 9, 16...)
as the program will arrange them in a cartesian grid. Each process will
handle a subgrid of size `s` by `s`, and the process with rank 0 will
print the number of cells alive at the end of the simulation.

In the rest of this tutorial, we will assume that you have built and installed
this example simulation and that you can run it "manually" on a cluster or
supercomputer (i.e., you can submit an interactive job and run the simulation
as an MPI application in it). We will walk our way backward, from wrapping
up the simulation in a Knit application, to scripting the job that will run
it, then scripting the way it is built.


## Getting started

Let's start by downloading [knit.sh] in a new folder (we will call the folder
the root folder from now on). In the root folder, let's start a Bash script named
`tutorial.sh`  with the following.

```bash
#!/usr/bin/env bash

source knit.sh

knit $@
```

The first line tells whatever shell you are using that this is a Bash script and
should be executed by Bash. The second line sources *knit.sh*. The third invoke
Knit's main function with the arguments passed to the script.

Make the script executable (`chmod +x tutorial.sh`). You can now give it a first
try with `./tutorial --help`.

You should already see in the help message a suggestion to set a description for
your experiment using `knit_set_program_description`, so let's do that now.

```bash
#!/usr/bin/env bash

source knit.sh

knit_set_program_description "Game of life tutorial experiment."
knit $@
```

Run `./tutorial.sh --help` again and you will see that the warning has now changed
to your description. We can now also *bootstrap* our experiment, that is, install
any software the Knit itself requires (not our code yet), and create the databases
and directory structures needed.

```bash
$ ./tutorial.sh bootstrap
```

You should find that your script has created a hidden *.knit* folder in the root folder.

## Making out first `app`

From now on, any piece of code that this tutorial will give should be placed after
`source knit.sh`, and before the final `knit $@`.

Any external binary used by an experiment as an MPI application (i.e., usually
run via `mpiexec` or equivalent) must be wrapped in a Knit *app*. This construct
makes Knit aware of the application and allows it to record information about its
execution in a database.

The following is an *app* wrapper for our `game-of-life` binary.

```bash
knit_register_app "game_of_life" "game_of_life_fn" "Game of life simulation."
knit_with_required "grid-size" "integer" "Grid size in each process."
knit_with_required "alive-ratio" "real" "Initial ratio of live cells (between 0 and 1)."
knit_with_required "iterations" "integer" "Number of iterations."
game_of_life_fn() {
    local size=$(knit_get_parameter "grid-size" $@)
    local ratio=$(knit_get_parameter "alive-ratio" $@)
    local iterations=$(knit_get_parameter "iterations" $@)
    game-of-life "${size}" "${ratio}" "${iterations}"
}
knit_done
```

`knit_register_app` is used to start the declaration of an application. Its first
argument is the name of the command by which the application will be known.
The second argument is the name of the function that defines the application.
The third is a description of the application.

Next come a series of calls to `knit_with_required`. These calls tell Knit the
parameters that are required by the application, providing a name, a type
(types can be `integer`, `real`, `boolean`, or `string`), and a description.

We then define the `game_of_life_fn` function wrapping the simulation. It uses
`knit_get_parameter` to extract parameters from its list of arguments, and calls
the `game-of-life` binary.

You may now call again `./tutorial.sh --help`, you will find the `game_of_life`
application listed. Call `./tutorial.sh game_of_life --help` to show its usage.
Finally, call the following to run the application.

```bash
$ ./tutorial.sh game_of_life --size 32 --alive 0.2 --iterations 10
```

If this command fails because `game-of-life` could not be found, simply add its
path to your `PATH` environment variable, for now. We will learn later how to
properly setup the required dependencies and environment variables.


## First step into Knit's database

Another way of running the previously defined  application is as follows.

```bash
$ ./tutorial.sh run game_of_life --size 32 --alive 0.2 --iterations 10
```

Contrary to `./tutorial.sh game_of_life`, you will see that this command simply
prints a UUID, instead of the game-of-life program's standard output. Run the
command a few times and you will see that this UUID is different each time.

So where has the output gone? Well, this is where the magic of Knit happens.
Run the following command to find out, replacing the UUID with one of the UUIDs
printed by one of your runs.

```bash
$ ./tutorial.sh db stdout game_of_life --id <uuid>
```

This command will print the corresponding run's output.
Next, run the following command.

```bash
$ ./tutorial.sh db show game_of_life
```

This command will print a table of the runs we have done of the `game_of_life`
app. Columns include the parameters that were passed, the runtime, and the path
of the files where their standard output and errors have been redirected.

Feel free to run `./tutorial.sh db show game_of_life --help` for a list of options
that you can use to display information from this database.

You now understand the power of Knit: not only does it make scripting an experiment
more descriptive and more understandable, it also records what your experiment is
doing in a database.

## Making a `job`


