..
   title: Set the scheduler project and account
   categories: bootstrap
   order: 20
   description: Record the batch-scheduler project and account jobs are submitted under.
   apis: bootstrap

On a shared cluster the batch scheduler charges each job to a **project** (or
allocation) and, on some sites, an **account**. These are values your site
assigns --- not free-form labels --- and Knit passes them to the scheduler when
submitting jobs. Freeze them at bootstrap so every submission inherits them:

.. code-block:: console

   $ ./exp.sh bootstrap \
       --project PROJ-1234 \
       --account my-allocation

``--project`` names the scheduler project used when submitting jobs;
``--account`` is the account/allocation the jobs are charged to. Leave them empty
on a laptop or any machine with no batch scheduler.
