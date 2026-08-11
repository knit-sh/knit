..
   title: Cancel or resubmit a job
   categories: jobs
   order: 50
   description: Stop a running job, or replay a past submission as a fresh job.
   apis: job:cancel, job:resubmit

Stop a running job with ``job cancel``. Knit asks the scheduler to terminate it;
the job's compute-side handler records the ``killed`` state as it goes down:

.. code-block:: console

   $ ./exp.sh job cancel --id "$id"

To run a job again with exactly the same inputs, use ``job resubmit``. Knit reads
the old job's recorded submission options (setup, nodes, walltime, ...) and its
job parameters from the database and reconstructs an equivalent ``submit``
invocation --- so a run is reproducible from its id alone, with nothing to
remember or retype:

.. code-block:: console

   $ new_id=$(./exp.sh job resubmit --id "$id")

Resubmitting always mints a **new** job UUID; the original id is never reused, so
the old run's records and outputs stay intact. This makes ``job resubmit`` the
building block for re-running a past experiment exactly as it was first run.
