..
   title: List the job types you can submit
   categories: jobs
   order: 15
   description: Discover registered jobs with submit --help and submit one with the -- dispatcher syntax.
   apis: submit

``submit`` is a *dispatcher*, not an ordinary parent command: the jobs registered
with ``knit_register_job`` are not nested subcommands of it, they are the tokens
you pass *after* ``--``. ``submit --help`` lists them under a **Jobs** heading:

.. code-block:: console

   $ ./exp.sh submit --help
   Usage: ./exp.sh submit [OPTIONS] -- <job> [OPTIONS]
   ...
   Jobs
   ----
     julia   Render a Julia-set fractal as a submitted job.

The usage line shows the shape to follow. A job is submitted as
``submit [scheduler options] -- <jobname> [job options]`` --- the ``--`` separates
the scheduler options (which belong to ``submit``) from the job's own options:

.. code-block:: console

   $ ./exp.sh submit --nodes 2 -- julia --width 1920

This is the one place Knit's invocation syntax departs from ordinary subcommand
nesting. Writing ``./exp.sh submit julia --width 1920`` (with no ``--``) does
**not** submit the ``julia`` job --- ``julia`` would be read as a stray argument
to ``submit`` itself. The ``--`` is required.

To see a *specific* job's parameters, name it before ``--help`` (no ``--``
needed for the help form): ``./exp.sh submit julia --help``.
