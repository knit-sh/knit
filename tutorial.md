# Tutorial

In this document, we will run through how to use Knit to make an experiment
reproducible. For this, we will use
[this repository](https://github.com/knit-sh/julia-fractal-example) as the
HPC code to run. This code is a simple
[Julia fractal](https://en.wikipedia.org/wiki/Julia_set) renderer written
in C++ and trivially parallelized using MPI. Once built and installed as
explained in its
[README](https://github.com/knit-sh/julia-fractal-example/blob/main/README.md)
file, it can be run as follows.

```bash
$ mpirun -np <N> julia-fractal <w> <h> <r> <i> <m> <o>
```

Where `w` and `h` are the dimensions of the grid (and resulting image),
`r` and `i` are the real and imaginary part of the Julia set's constant,
`m` is the maximum number of iterations to check for divergence, and
`o` is an optional PNG file name in which to store the image.

In the rest of this tutorial, we will assume that you have built and installed
this example simulation and that you can run it "manually" on a cluster or
supercomputer (i.e., you can submit an interactive job and run the program
as an MPI application in it). We will walk our way backward, from wrapping
up the program in a Knit application, to scripting the job that will run
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

knit_set_program_description "Julia set tutorial experiment."
knit $@
```

Run `./tutorial.sh --help` again and you will see that the warning has now changed
to your description. We can now also *bootstrap* our experiment, that is, install
any software that Knit itself requires (not our code yet), and create the databases
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
knit_register_app "julia" "julia_fractal_fn" "Julia fractal computation."
knit_with_required "grid-width"      "integer" "Width of the grid (and image)."
knit_with_required "grid-height"     "integer" "Height of the grid (and image)."
knit_with_required "c-real"          "real"    "Real part of the parameter of the Julia set."
knit_with_required "c-imaginary"     "real"    "Imaginary part of the parameter of the Julia set."
knit_with_optional "max-iterations"  "integer" 1000 "Max number of iterations for convergence."
knit_with_optional "output-filename" "string"  ""   "Path to the output PNG file."
julia_fractal_fn() {
    local w h m r i o
    w=$(knit_get_parameter "grid-width" $@)
    h=$(knit_get_parameter "grid-height" $@)
    m=$(knit_get_parameter "max-iterations" $@)
    r=$(knit_get_parameter "c-real" $@)
    i=$(knit_get_parameter "c-imaginary" $@)
    o=$(knit_get_parameter "output_filename" $@)
    julia-fractal "${w}" "${h}" "${r}" "${i}" "${m}" "${o}"
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

We then define the `julia_fractal_fn` function wrapping our program. It uses
`knit_get_parameter` to extract parameters from its list of arguments, and calls
the `julia-fractal` binary.

You may now call again `./tutorial.sh --help`, you will find the `julia`
application listed. Call `./tutorial.sh julia --help` to show its usage.
Finally, call the following to run the application.

```bash
$ ./tutorial.sh julia --grid-width 800 --grid-height 600 \
                      --c-real -0.8 --c-imaginary 0.156  \
                      --max-iterations 1000 \
                      --output-filename julia.png
```

If this command fails because `julia-fractal` could not be found, simply add its
path to your `PATH` environment variable, for now. We will learn later how to
properly setup the required dependencies and environment variables.

The above command simply prints a UUID, instead of the `julia-fractal` program's
standard output. Run the command a few times and you will see that this UUID is
different each time. The next section will explain what these UUIDs are and how
to get the output of the call.

So far all we have done is wrap an executable within a Bash function and defined
its parameters. You will note that contrary to the executable itself, the function
required *named parameters`, i.e. `--grid-width 800` instead of just `800`.
Knit only uses named parameters, forcing users to make their program's input as
descriptive as possible. We recommend using parameter names that are as explicit
as possible, as these parameter names will turn into columns in database tables.


## First step into Knit's database

Earlier we have invoked the `julia-fractal` executable through Knit. We only got
a UUID printed on our terminal. So where has the actual output gone? Well, this is
where some of the magic of Knit happens. Run the following command to find out,
replacing the UUID with one of the UUIDs printed by one of your runs.

```bash
$ ./tutorial.sh stdout --id <uuid>
```

This command will print the corresponding run's output.
Next, run the following command.

```bash
$ ./tutorial.sh db show julia
```

This command will print a table of the runs we have done of the `julia` app.
Columns include the parameters that were passed, the runtime, and the path
of the files where their standard output and errors have been redirected.

Feel free to run `./tutorial.sh db show julia --help` for a list of options
that you can use to display information from this database's table.

You now understand the power of Knit: not only does it make scripting an experiment
more descriptive and more understandable, it also records what your experiment is
doing in a database.


## Invoking an `app` from a `job`

Typically on a supercomputer, application binaries are invoked within a job. We
will therefore define such a job in our `tutorial.sh` script. After the definition
of the `julia` app, add the following.

```bash
knit_register_job "myjob" "my_job_fn" "Job for a julia fractal computation."
knit_with_params_from "julia" "c-real" "c-imaginary"
my_job_fn() {
    local r i
    r=$(knit_get_parameter "c-real" $@)
    i=$(knit_get_parameter "c-imaginary" $@)
    knit julia --grid-width 800 --grid-height 600 \
               --c-real ${r} --c-imaginary ${i}   \
               --max-iterations 1000              \
               --output-filename julia.png
}
knit_done
```

Just like with an `app`, a `job` can be declared with a list of parameters,
required or optional. Here, to avoid repetitions, `knit_with_params_from` is
used to tell Knit that the job takes the same `c-real` and `c-imaginary`
parameters as the `julia` app. Inside the function defining the job, we
hard-coded the remaining parameters.

You may now submit a job as follows.

```bash
./tutorial.sh submit myjob --c-real -0.8 --c-imaginary 0.156
```

Once again, you will get a UUID as the output. Contrary to an app, a job runs
in the background after the `submit` command has been issued. On a local machine
with no job scheduler, this simply means that the above command started a
background process in which the job's function actually executes. We will see
later how it works on a real supercomputer with job schedulers such as Slurm.

And again, we have a database table storing jobs we have submitted. The
following will show the table for our `myjob` jobs.

```bash
$ ./tutorial.sh db show myjob
```


## Emmitting results

A typical job or application will often not just take a bunch of parameters, it
may also emmit results. If you have manually executed the `julia-fractal`
program, or checked its output from one of our previous runs, you should have
seen that it displays a message like "Number of grid points within the set: 181".
This is the number of points for which the program reached the maximum number of
iterations without diverging (this is not strictly the number of points in the set,
but we will call it that nonetheless).

We will change our job definition as follows.

```bash
knit_register_job "myjob" "my_job_fn" "Job for a julia fractal computation."
knit_with_params_from "julia" "c-real" "c-imaginary"
knit_with_output "points-in-set" "integer" "Number of grid points within the set."
my_job_fn() {
    local r i uuid result
    r=$(knit_get_parameter "c-real" $@)
    i=$(knit_get_parameter "c-imaginary" $@)
    uuid=$(knit julia --grid-width 800 --grid-height 600 \
                      --c-real ${r} --c-imaginary ${i}   \
                      --max-iterations 1000              \
                      --output-filename julia.png)
    result=$(knit stdout --id "${uuid}"                    \
            | grep "Number of grid points within the set:" \
            | awk '{print $NF}')
    knit_output "points-in-set" "${result}"
}
knit_done
```

Here we have assigned the UUID returned by `knit julia`, and used it to access its
output with `knit stdout`. We pipe this output to `grep` and `awk` to extract the
value, which we then set using `knit_output`.

By submitting another `myjob` and examining the database using
`./tutorial.sh db show myjob`, you will find that the table now has another column
named "points-in-set" for the result of the job.

`knit_with_output` may be used multiple times to defined as many output columns as
needed. Knit will issue a warning if `knit_output` is not called for one of the
expected outputs.


## Running MPI applications

In the above job, we have run the `julia` app as a single process, but this
program is an MPI application that we may want to execute on some compute nodes
using `mpirun`. Bellow is a modification of our job to do just that.

```bash
knit_register_job "myjob" "my_job_fn" "Job for a julia fractal computation."
knit_with_params_from "julia" "c-real" "c-imaginary"
knit_with_output "points-in-set" "integer" "Number of grid points within the set."
my_job_fn() {
    local r i uuid result
    r=$(knit_get_parameter "c-real" $@)
    i=$(knit_get_parameter "c-imaginary" $@)
    uuid=$(knit run julia --placement "default"
                          --grid-width 800 --grid-height 600 \
                          --c-real ${r} --c-imaginary ${i}   \
                          --max-iterations 1000              \
                          --output-filename julia.png)
    result=$(knit stdout --id "${uuid}"                    \
            | grep "Number of grid points within the set:" \
            | awk '{print $NF}')
    knit_output "points-in-set" "${result}"
}
knit_done
```

The only differences with our previous version is the use of `knit run julia`
instead of `knit julia`. `knit run <app>` accepts the same arguments as the app
it runs, with the addition of a `--placement` argument. Here *"default"* means
"all the nodes/cores allocated to the job", e.g. if the job has 4 nodes with 32
cores each, our `julia` app will run as an MPI application with 128 ranks
spanning all these cores and nodes.

We will learn later how to specify different placements for our MPI
applications. For now, you can call `./tutorial.sh submit myjob ...` again and
check that the job continues to work. Knit should automatically detect your MPI
installation and run the `julia` app as a single-rank MPI application.


## Installing dependencies with a `setup`

So far we have built our `julia-fractal` program ourselves, and used spack to
install its dependencies. This is something our script should be tought to do
by itself, using a `setup`. The following will create such a setup for us. It
should be placed after `source knit.sh`, and before the definition of our apps
and jobs.

```bash
knit_register_setup "mysetup" "my_setup_fn" "Setup for the julia program."
knit_with_spack_specs "cmake" "mpi" "libpng"
knit_with_optional "julia-version" "string" "main" "Tag, branch, or commit to checkout."
my_setup_fn() {
    local version prefix
    version=$(knit_get_parameter "julia-version" $@)
    prefix=$(knit_get_setup_install_prefix)
    knit download git --url https://github.com/knit-sh/julia-fractal-example.git \
                      --ref "${version}"
    pushd julia-fractal-example
    cmake --install-prefix "${prefix}"
    cmake --build
    cmake --install
    popd # julia-fractal-example
}
```

A `setup` is registered using `knit_register_setup`. Just like any other
commands, it can be parameterized (e.g. here with `knit_with_optional` to
specify the version, tag, branch, or commit number of the julia-fractal-example
code that we want to checkout). And just like any other command, its execution
will be recorded in a table.

Before explaining it further, let's call our setup, as follows.

```bash
./tutorial.sh setup mysetup --name julia-setup --julia-version v1.0
```

A `setup` works by creating a directory with the specified name, here
*"julia-setup"*, and using it to install software and download data.

`knit_with_spack_specs` lets us list some specs that we need to install with
spack. From this line, Knit will automatically infer that it should download
and install spack (a single installation of spack will be placed in the `.knit`
hidden folder and will be shared between setups). It will also create an
environment for the setup in the setup's folder.

`knit_get_setup_install_prefix` can be used inside the setup's function to
retrieve a path where it is suitable to install software for the setup.

To download the julia software, We use `knit download git` instead of manually
calling `git clone` and `git checkout`. `knit download git` is an all-in-one
command that will not only do this for you, but also record it in Knit's
database.

Finally, another key difference between a `setup` and other kinds of commands
is that Knit will record the environment variables of a setup after having
built it.

# Making jobs depend on setups

We can now delete our manually installed spack and julia-fractal, or at least
remove them from our PATH. We have a setup to install our software. Still, we
should tell Knit that `myjob` requires a setup of type `mysetup` in order
to run. We do this as follows when registering our job.

```bash
knit_register_job "myjob" "my_job_fn" "Job for a julia fractal computation."
knit_with_setup "mysetup"
...
```
