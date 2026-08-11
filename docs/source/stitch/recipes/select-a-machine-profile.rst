..
   title: Select a machine profile
   categories: profiles
   order: 10
   description: Pass bootstrap --profile to prepopulate scheduler, launcher, and hardware defaults from a shared machine description.
   apis: bootstrap, profile:list, profile:show

A **machine profile** is a shared JSON description of a cluster --- its
scheduler, MPI launcher, default queue, and per-node core/GPU counts. Selecting
one at bootstrap saves you from spelling those out by hand and keeps every
experiment on that machine consistent.

See which profiles are available, and inspect one before committing to it:

.. code-block:: console

   $ ./exp.sh profile list
     polaris   [github] Argonne Polaris (PBS, MPICH).
     perlmutter  [github] NERSC Perlmutter (Slurm, Cray MPICH).
   $ ./exp.sh profile show anl/polaris

``profile list`` and ``profile show`` work **before** bootstrap, so you can
browse first. A profile spec is a shorthand like ``anl/polaris``, a URL, or a
local file --- handy for a machine that is not in the public index.

Then bootstrap with it:

.. code-block:: console

   $ ./exp.sh bootstrap --profile anl/polaris --project m1234

The profile's values become the defaults for ``--scheduler``, ``--launcher``,
``--default-cpus-per-node``, and the rest, so an explicit flag is only needed to
override one. The resolved profile is **frozen into the experiment's metadata**
at bootstrap, so the experiment stays reproducible even if the shared profile
later changes; ``profile show`` on a bootstrapped experiment prints that frozen
copy. Read individual fields from a script with *Read a profile field in a
script*.
