..
   title: Keep setup functions thin
   categories: setup
   order: 15
   description: Delegate dependency installation to a package manager and keep the setup body minimal.
   apis: knit_with_spack_specs, knit_with_spack_env

A setup body should do as little as possible. Every command it runs by hand ---
cloning a repository, ``./configure``, ``make``, downloading a tarball --- is one
more thing a reproducer has to trust to behave identically on a different machine,
and one more thing knit cannot capture as provenance. The more the body does, the
less reproducible the setup.

Prefer declaring dependencies with ``knit_with_spack_specs`` (or a full
``knit_with_spack_env`` manifest) and letting Spack build them. Spack pins
versions, compilers, and variants, records a concrete lockfile (captured as a
provenance output on the setup's table), and reuses already-built packages across
setups --- far more reproducible than an imperative build script. In the ideal
case the body is *empty*: everything the experiment needs is a Spack spec, so the
setup is just a list of specs.

When your own program is not yet a Spack package --- as in the julia-fractal
example, whose setup clones the source and builds it with CMake by hand --- the
most reproducible path is to write a small Spack package for it (a ``package.py``
in a custom repo) and add it to the specs. The hand-written clone/configure/build
steps then become one more spec that Spack builds, versions, and locks like any
other dependency, and the setup body shrinks to nothing.

Keep in the body only what genuinely cannot be a package: writing a config or
params file, exporting an environment variable, or creating a directory under
``KNIT_SETUP_PREFIX``.
