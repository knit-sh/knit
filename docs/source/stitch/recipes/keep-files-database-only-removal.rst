..
   title: Remove the records only, keep every file
   categories: cleanup
   order: 41
   description: Erase the database rows and edges of a removal while making no filesystem change at all --- every directory, artifact, and plain output stays.
   apis: remove:job, remove:artifact

When you want the provenance out of the database but the **whole on-disk tree**
left exactly as it is, use ``--keep-files``. It erases the database side as usual
(every row and provenance edge in the set) but makes **no** filesystem change:
job, setup, and resource directories, artifact entries, and plain outputs all
stay:

.. code-block:: console

   $ ./exp.sh remove job --id "$id" --keep-files --yes
   Erased:
     ...
   The following files/directories were NOT removed:
     jobs/018f9c3a-...      (job directory, --keep-files)
     artifacts/result.txt   (artifact, --keep-files)

Everything that stays is listed under **Left on disk**, tagged by kind, so the
record of what survived is explicit. This is the superset of
``--keep-artifacts``: that flag keeps only the artifact entries and still removes
the directories, while ``--keep-files`` keeps the directories too. If you pass
both, ``--keep-files`` wins.

Because the rows and edges are gone, none of the kept files are tracked any more:
they will not be re-checksummed, exported, or found by a provenance walk.
``--keep-files`` discards the record while leaving the bytes untouched.
