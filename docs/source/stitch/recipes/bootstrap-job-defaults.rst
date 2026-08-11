..
   title: Set project-wide job defaults
   categories: bootstrap
   order: 60
   description: Freeze default walltime and per-node core count for submitted jobs.
   apis: bootstrap

``bootstrap`` can freeze project-wide defaults that every submission inherits
unless a job overrides them. ``--default-walltime`` sets a wall-clock limit as
``HH:MM:SS``; ``--default-cpus-per-node`` sets the core count used for whole-node
allocation:

.. code-block:: console

   $ ./exp.sh bootstrap \
       --default-walltime 01:30:00 \
       --default-cpus-per-node 64

Left empty, walltime falls back to the selected queue's profile default at submit
time, and the per-node core count falls back to the machine profile or live
detection.
