..
   title: Read a rank's place in the MPI world
   categories: apps
   order: 15
   description: An app body branches on its own rank via the normalized KNIT_MPI_RANK, KNIT_MPI_SIZE, and KNIT_MPI_LOCAL_RANK.
   apis: KNIT_MPI_RANK, KNIT_MPI_SIZE, KNIT_MPI_LOCAL_RANK

An app body runs once per rank. When it needs to know *which* rank it is --- to
split work, or to let one rank do something the others don't --- it reads the
three environment variables knit exports into every rank:

- ``KNIT_MPI_RANK`` --- this rank's index in ``MPI_COMM_WORLD`` (0-based).
- ``KNIT_MPI_SIZE`` --- the total number of ranks in ``MPI_COMM_WORLD``.
- ``KNIT_MPI_LOCAL_RANK`` --- this rank's index among the ranks on its own node.

.. code-block:: bash

   if [[ "${KNIT_MPI_RANK}" == "0" ]]; then
       printf 'world has %s ranks\n' "${KNIT_MPI_SIZE}"
   fi

Knit fills these from whichever launcher actually ran --- Open MPI
(``OMPI_COMM_WORLD_*``), MPICH/Hydra (``PMI_*``), Slurm (``SLURM_PROCID`` /
``SLURM_NTASKS`` / ``SLURM_LOCALID``), PALS (``PALS_*``), and so on. Reading the
normalized ``KNIT_MPI_*`` names means the same app body works unchanged across
backends, instead of hard-coding one launcher's variables.

On a laptop (the ``none`` launcher, a single process) ``KNIT_MPI_RANK`` is ``0``,
``KNIT_MPI_SIZE`` is ``1``, and ``KNIT_MPI_LOCAL_RANK`` is ``0``, so a body
written against these variables still runs correctly with no launcher at all.

You rarely need to guard ``knit_output`` with a rank check: knit already records
only from rank 0 (see *Register an MPI app*). These variables are for the app's
*own* logic --- deciding which slice of the problem each rank computes.
