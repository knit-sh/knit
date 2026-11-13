..
   title: Make a spec depend on a parameter
   categories: spack, setup
   order: 15
   description: Reference a setup parameter from a spec or manifest with a {{placeholder}}.
   apis: knit_with_spack_specs, knit_with_spack_env, knit_with_uv_specs, knit_with_required, knit_with_optional

A setup's environment can depend on its parameters. Write a
``{{parameter-name}}`` placeholder anywhere in a spec (or a manifest) and Knit
replaces it, when the setup runs, with the value of that setup parameter --- so
one setup definition builds whatever version the invocation asks for:

.. knit-code:: /_code/parameterized_specs.sh
   :language: bash
   :start-after: # START specs
   :end-before: # END specs

Invoking ``knit setup -- mathlibs --openblas-version 0.3.28`` renders the spec to
``openblas@0.3.28`` before the environment is built. The *rendered* (concrete)
manifest is what Knit records as provenance, so a reproducer reads
``openblas@0.3.28``, not the template.

``knit_with_spack_specs`` takes one or more specs, and several calls on the same
setup **add up** into one spec list (group them however reads best). A setup can
instead declare a complete manifest with ``knit_with_spack_env``; the two forms
are mutually exclusive on one setup. To choose specs *structurally* --- one spec
per computed item, or a spec added only under a flag --- a function can generate
them (see the *Generate specs or a manifest with a function* recipe).

The same ``{{placeholder}}`` works wherever an environment comes from --- the
``knit_with_spack_specs`` sugar above, a here-doc or file manifest passed to
``knit_with_spack_env``, and the matching directives of any other environment
manager (for example ``knit_with_uv_specs "numpy=={{numpy-version}}"``). A
placeholder whose name does not match a declared parameter is a fatal error when
the setup runs, naming the offending ``{{token}}``. The placeholder name follows
Knit's usual rule that hyphens and underscores are interchangeable
(``{{openblas-version}}`` is the same as ``{{openblas_version}}``).
