..
   title: Run Spack directly
   categories: spack
   order: 40
   description: Drive the experiment's private Spack with the knit spack wrapper.
   apis: spack, bootstrap

The ``spack`` command comes from the Spack **plugin** --- ``knit_import spack``
just after ``source knit.sh`` adds it. It is a thin wrapper that forwards every
argument verbatim to the experiment's private Spack, so you can inspect and drive
it exactly as you would a system Spack --- without it leaking onto your ``PATH``:

.. code-block:: console

   $ ./exp.sh spack find            # what is installed
   $ ./exp.sh spack spec zlib       # how a spec would concretize
   $ ./exp.sh spack --help          # Spack's own help, forwarded

Because the wrapper forwards ``--help`` too, ``./exp.sh spack --help`` shows
Spack's help rather than knit's. The private Spack is provisioned automatically
the first time a setup declares a Spack environment; run ``knit spack`` before
Spack is provisioned and it fails with a hint to run ``bootstrap --spack`` first.
To provision it eagerly and pin its version at bootstrap, see the *Pin the Spack
version* recipe in the Bootstrap category.
