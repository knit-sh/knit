..
   title: Isolate Spack from your personal config
   categories: spack
   order: 50
   description: Knit's Spack ignores ~/.spack and site config so the environment stays reproducible.
   apis: spack

The Spack that knit provisions is deliberately walled off from your personal and
site-wide Spack configuration, so an experiment concretizes the same way no matter
whose machine or account it runs on. Knit exports two environment variables for
its Spack:

- ``SPACK_DISABLE_LOCAL_CONFIG=true`` --- Spack ignores both the system scope and
  your ``~/.spack`` user scope.
- ``SPACK_USER_CONFIG_PATH`` pointing at a directory inside the experiment
  (``.knit/.spack``) --- any user-scope config Spack reads or writes lives with
  the experiment, not in your home directory.

The upshot is that what the experiment builds is determined only by the
specs/manifest in the script plus knit's own config under ``.knit`` --- both of
which travel with the experiment --- so a stray package preference, mirror, or
compiler default in ``~/.spack`` can neither leak into nor silently change the
build. To customize the environment, put the settings in the manifest (see *Use a
full Spack manifest*) or edit knit's own scope with ``knit spack config``, rather
than in ``~/.spack``.
