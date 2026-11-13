..
   title: Generate specs or a manifest with a function
   categories: spack, setup
   order: 16
   description: Let a function produce a setup's specs (or whole manifest) at invocation time.
   apis: knit_with_spack_specs_from, knit_with_spack_env_from, knit_with_uv_specs_from, knit_with_uv_env_from, knit_get_parameter, knit_with_flag, knit_with_required

A ``{{placeholder}}`` fills a *value* into a fixed shape. When the **shape**
itself depends on a parameter --- add a spec only under a flag, emit one spec per
computed item --- let a function build it. ``knit_with_<manager>_specs_from``
names a function that prints newline-separated specs on stdout when the setup
runs:

.. knit-code:: /_code/generate_specs_with_a_function.sh
   :language: bash
   :start-after: # START specs_from
   :end-before: # END specs_from

The function is called with the setup's arguments as ``"$@"``, so it reads
parameters with ``knit_get_parameter`` exactly as a setup body does (a flag
arrives as the string ``true`` or ``false``). Each non-blank line it prints is a
spec, still rendered for ``{{...}}`` --- so the function chooses *which* specs and
``{{...}}`` fills in *values*. The printed specs join the setup's spec list, so
``knit_with_spack_specs_from`` and plain ``knit_with_spack_specs`` compose in any
order.

To generate a **whole manifest** (a complete ``spack.yaml`` or
``pyproject.toml``) rather than a spec list, use ``knit_with_<manager>_env_from``
--- the programmatic twin of ``knit_with_spack_env``:

.. knit-code:: /_code/generate_specs_with_a_function.sh
   :language: bash
   :start-after: # START env_from
   :end-before: # END env_from

A setup declares **either** a spec list (any number of ``..._specs`` /
``..._specs_from`` calls, which add up) **or** one complete manifest (a single
``..._env`` / ``..._env_from``); the two forms are mutually exclusive on one
setup. A function that exits non-zero aborts the setup before anything is built,
and an empty final spec list is a fatal error. The ``_from`` directives exist for
every environment manager (``knit_with_uv_specs_from``,
``knit_with_uv_env_from``, and so on), each with its ``@`` shorthand.
