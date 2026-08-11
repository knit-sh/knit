..
   title: Choose where setups and jobs live
   categories: bootstrap
   order: 30
   description: Point the setup and job root directories at custom locations.
   apis: bootstrap

Knit creates each setup and each submitted job under a root directory.
``--setup-path`` and ``--job-path`` choose those roots (defaults: ``setups`` and
``jobs``):

.. code-block:: console

   $ ./exp.sh bootstrap \
       --setup-path env \
       --job-path runs

Keep these paths **relative** --- they resolve against the experiment root, so
the experiment stays portable to another machine or user. An absolute path is
honored but pins the experiment to this filesystem, and Knit warns when you pass
one.
