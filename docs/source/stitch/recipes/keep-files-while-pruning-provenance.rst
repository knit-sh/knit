..
   title: Keep the files while pruning provenance
   categories: cleanup
   order: 40
   description: Erase the database rows and edges of a removal but leave the artifact files on disk, listed under "Left on disk".
   apis: remove:job, remove:artifact

Sometimes you want a run out of the database but its **output files** kept ---
to archive them by hand, or hand them off before pruning the provenance.
``--keep-files`` does exactly that: it erases the database side as usual (every
row and provenance edge in the set, including each artifact's ``artifacts`` row
and its ``produced`` edge) but does **not** delete the on-disk artifact entries
under ``artifacts/``:

.. code-block:: console

   $ ./exp.sh remove job --id "$id" --keep-files --yes
   Erased:
     ...
   The following files/directories were NOT removed:
     artifacts/result.txt   (artifact, --keep-files)

The kept entries are listed in a **Left on disk** section so the record of what
survived is explicit. Scope is **artifacts only**: job, setup, and resource
directories are framework-managed containers and are still removed (keeping them
would just orphan them). Plain (non-artifact) command outputs are *always* left
on disk and listed there too, with or without the flag --- remove never deletes a
file you wrote outside the ``artifacts/`` root.

Because the artifact rows are gone, the kept files are no longer tracked: they
will not be re-checksummed, exported, or found by a provenance walk. ``--keep-files``
is about salvaging bytes while discarding the record, not about keeping a partial
record.
