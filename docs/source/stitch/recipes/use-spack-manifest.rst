..
   title: Use a full Spack manifest
   categories: spack
   order: 20
   description: Describe a setup's Spack environment with a complete spack.yaml.
   apis: knit_with_spack_env, knit_register_setup

When you need full control over the environment --- versions, variants,
compilers, views, package preferences --- describe it with a complete
``spack.yaml`` manifest via ``knit_with_spack_env``. Point it at a file checked in
next to the experiment:

.. knit-code:: /_code/spack_manifest.sh
   :language: bash
   :start-after: # START env-file
   :end-before: # END env-file

Or, when the manifest is short and specific to the experiment, inline it with a
here-doc (any redirected stdin works). The manifest is read at registration time,
so it must actually be redirected --- an interactive terminal or an empty manifest
is rejected rather than left to block:

.. knit-code:: /_code/spack_manifest.sh
   :language: bash
   :start-after: # START env-stdin
   :end-before: # END env-stdin

A setup may declare at most one Spack environment, and ``knit_with_spack_env`` is
mutually exclusive with the ``knit_with_spack_specs`` sugar (which funnels through
it). As with specs, the concrete manifest and lockfile are captured as provenance
outputs on the setup's table. The Spack itself is knit's own, installed under
``.knit/`` at ``bootstrap`` time --- declaring any Spack-backed setup makes
bootstrap detect that the experiment needs Spack and provision it, and
``bootstrap --spack`` provisions (and pins) it explicitly.
