..
   title: Erase a whole lineage with --from-root
   categories: cleanup
   order: 30
   description: Point at any row (or an artifact) and erase the entire call/produced tree it belongs to, both up to the root and back down.
   apis: remove:artifact, remove:job

By default remove only cascades **downward** and refuses to erase a row whose
caller or producer is kept --- so naming an **artifact** on its own fails, because
its producing invocation would be left dangling:

.. code-block:: console

   $ ./exp.sh remove artifact --path result.txt
   [knit:fatal] remove: cannot erase artifact ...; it was produced by
   "submit:crunch" ..., which is not being erased. Pass --from-root to erase the
   whole lineage.

``--from-root`` widens the erase set to the **whole call/produced lineage tree**
the selection belongs to. remove first walks **up** ``call`` and ``produced``
edges to the root of the tree, then removes the entire tree downward --- so
pointing at any row, or at an artifact, erases everything in its lineage:

.. code-block:: console

   $ ./exp.sh remove artifact --path result.txt --from-root

This is the tool for pruning a complete experiment branch: the producing command,
its parent submission, sibling outputs, and every artifact in the tree all go
together. ``used_by`` edges are **never** followed either way, so a setup or
resource that the tree used is still left intact --- ``--from-root`` widens along
the *lineage*, not along shared providers. Combine it with ``--dry-run`` first to
see the full tree before committing.
