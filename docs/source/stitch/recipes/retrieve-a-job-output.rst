..
   title: Retrieve a job's output
   categories: jobs
   order: 40
   description: Print a job's captured stdout, stderr, and generated batch script by id.
   apis: job:show:stdout, job:show:stderr, job:show:script

A job's standard output and error are always captured to files in its working
directory, and the batch script knit generated to run it is kept alongside them.
Retrieve any of the three by the job's UUID --- no need to know the paths:

.. code-block:: console

   $ ./exp.sh job show:stdout --id "$id"
   $ ./exp.sh job show:stderr --id "$id"
   $ ./exp.sh job show:script --id "$id"

``show:stdout`` and ``show:stderr`` accept ``--follow`` to stream the file as it
grows, like ``tail -f`` --- handy for watching a still-running job:

.. code-block:: console

   $ ./exp.sh job show:stdout --id "$id" --follow

``show:script`` prints the exact scheduler script knit submitted (its directives,
the setup activation, and the ``submit`` line it re-invokes on the compute node),
which is the first thing to read when a job behaves unexpectedly.
