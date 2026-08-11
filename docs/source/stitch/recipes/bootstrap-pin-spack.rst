..
   title: Pin the Spack version
   categories: bootstrap, spack
   order: 70
   description: Provision a specific Spack (and package repo) git ref at bootstrap.
   apis: bootstrap

Knit provisions a private Spack **automatically** the first time a setup declares
a Spack environment, defaulting to the latest Spack release. Pass ``--spack`` to
pin a specific Spack git ref (a tag, branch, or commit) instead, and
``--spack-packages`` to pin the package repository ref:

.. code-block:: console

   $ ./exp.sh bootstrap \
       --spack v0.22.1 \
       --spack-packages v2024.11.0

Both take a git ref as their value; an empty value (the default) uses the latest
release. Passing ``--spack`` also forces Spack to be provisioned now rather than
lazily on first use.
