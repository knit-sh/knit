..
   title: Write results into the job's directory
   categories: jobs
   order: 25
   description: Use KNIT_JOB_PREFIX, the job's own working directory, to place output files.
   apis: KNIT_JOB_PREFIX

Every job runs in its own directory under the job root (``<job-root>/<uuid>``),
exported to the body as ``KNIT_JOB_PREFIX`` and already set as the process's
current directory. Anything the job writes there travels with the run's records,
so this is where output files belong:

.. knit-code:: /_code/julia_job.sh
   :language: bash
   :start-after: # START job
   :end-before: # END job

Because ``KNIT_JOB_PREFIX`` is already the working directory, a bare relative path
(``fractal.png``) lands there too. Building an *absolute* path from
``KNIT_JOB_PREFIX`` --- as the body above does --- is still worth it: it is
explicit about where the file belongs and stays correct even if the body, or a
program it launches, changes directory first.

The basename of ``KNIT_JOB_PREFIX`` is the job's UUID --- the same id ``submit``
printed and the key used by ``job show``, ``job status``, and the rest of the
``job`` commands --- so a job can also derive its own id from it if it needs to.
``KNIT_JOB_PREFIX`` is set only while a job runs; it is unset on the login/submit
side.
