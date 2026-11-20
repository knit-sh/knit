..
   title: Run on a filesystem without flock
   categories: bootstrap
   order: 45
   description: Choose the database write-lock mechanism when the default flock is unsupported.
   apis: bootstrap

Knit uses a file lock so that only one process writes to its database at a time.
The default lock is ``flock``. It needs a filesystem that supports file locking.
Most filesystems do. Some HPC filesystems do not. On NERSC Perlmutter, for
example, a compute node sees ``$HOME`` through a layer (DVS) that does not
support ``flock``, so a job that writes to the database fails with
``flock: ... Unknown error 524``.

You have two choices. The easier one is to put the experiment on a filesystem
that supports locking (on Perlmutter, ``$PSCRATCH``). If you must keep the
experiment on a filesystem without ``flock``, bootstrap with ``--db-lock
mkdir``:

.. code-block:: console

   $ ./exp.sh bootstrap --db-lock mkdir

``mkdir`` mode uses an atomic directory as the lock. This works on a filesystem
that does not support ``flock``. If a process cannot get the lock in 60 seconds,
it stops and tells you to remove a stray lock by hand. Only a hard kill
(``SIGKILL``) can leave such a lock.

``--db-lock`` has three values:

- ``flock`` (default): advisory file locks. Needs a filesystem that supports
  them.
- ``mkdir``: an atomic directory lock. Works without ``flock``.
- ``none``: no lock. Use it only when no two Knit writes can happen at the same
  time.

You set the mechanism once, at bootstrap. To change it later, run ``bootstrap``
again with a different ``--db-lock``. Knit rewrites the stored choice. There is
nothing to migrate.
