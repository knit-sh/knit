Tutorial
========

The :doc:`../quickstart` showed the mechanics of a single recorded command.
This tutorial walks you towards a real experiment, built from beginning to end,
around a real program: `julia-fractal
<https://github.com/knit-sh/julia-fractal-example>`_, a small C++ renderer for
`Julia-set <https://en.wikipedia.org/wiki/Julia_set>`_ fractals. We start with a
plain command that tries to run it and turn it, step by step, into a
Spack-backed, MPI-parallel, fully recorded experiment. Along the way you use
setups, jobs, apps, and the query and provenance surfaces together on a single
realistic workload.

The tutorial comes in two parts:

- :doc:`part1` --- the fast overview. It builds the experiment end to end, from a
  plain command to a Spack-backed, MPI-parallel, recorded workload running on a
  supercomputer, introducing exactly one new concept per step.
- :doc:`part2` --- a refinement pass over the *same* experiment. It follows the
  same setup→run order and, section by section, improves each piece with a Knit
  capability that makes it cleaner, safer, or more reproducible.

Read Part I first for the whole picture, then Part II to sharpen it. Each part
stands on its own page so both stay easy to read.

.. toctree::
   :maxdepth: 2

   part1
   part2
