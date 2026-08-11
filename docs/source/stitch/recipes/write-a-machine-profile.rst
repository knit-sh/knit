..
   title: Write a machine profile
   categories: profiles
   order: 40
   description: Guidance for profile authors — capture only what the experiment cannot do itself, and keep the Spack section to vendor packages.
   apis: bootstrap, knit_with_spack_specs

Writing a profile for a new machine (see *Anatomy of a machine profile* for the
format) comes down to one principle: **a profile captures only what an experiment
script cannot do for itself.** A profile is machine truth --- which scheduler,
which launcher, how many cores and GPUs per node, which vendor libraries the
site provides --- not a snapshot of everything installed on the login node.

The ``spack`` section is where this discipline matters most. Restrict it to
**vendor packages**: the software that is tied to the machine and must come from
the site, not from a portable build. On a typical HPC system that is the tuned
MPI, the network fabric library, the GPU runtime, and the compilers --- exactly
what the Polaris profile lists (``cray-mpich``, ``libfabric``). Register those as
non-buildable externals::

   "cray-mpich": {
       "externals": [ { "spec": "cray-mpich@9.0.1", "prefix": "/opt/cray/pe/mpich/9.0.1/ofi/gnu/12.3" } ],
       "buildable": false
   }

and, where the machine provides a specific implementation of a virtual package,
point the virtual at it (``"mpi": { "require": ["cray-mpich"] }``) so every
setup's ``knit_with_spack_specs "mpi"`` resolves to the vendor stack.

Do **not** add externals for software the experiment can build itself. Even if
the platform ships ``cmake``, ``git``, or a recent ``python``, leave them out of
the profile: an experiment's own Spack environment can build those portably, and
pinning them to a site path only makes the experiment less reproducible and
harder to move to the next machine. A profile that lists CMake as an external is
describing the login node, not the machine. The test for each Spack entry is:
*could a setup build this correctly on its own?* If yes, it belongs in a setup's
``knit_with_spack_specs``, not in the profile.

The same restraint applies to ``modules``: list only the modules needed to reach
the vendor software (the programming environment, an MPI module), not a personal
working set. Keep profiles small, vendor-focused, and durable --- they should
change only when the machine does.
