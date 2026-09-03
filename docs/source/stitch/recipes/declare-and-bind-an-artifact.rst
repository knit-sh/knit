..
   title: Declare and bind an artifact
   categories: artifacts
   order: 50
   description: Declare a produced file with knit_with_output_artifact, write it under knit_artifact_dir, then bind it with knit_artifact.
   apis: knit_with_output_artifact, knit_artifact_dir, knit_artifact

An **artifact** is a file or directory a command produces that you want kept for
export --- a dataset, a plot, a captured config. Declare it with
``knit_with_output_artifact "name:type" "description"`` (the type must be ``file`` or
``directory``), write it under the artifacts root reported by
``knit_artifact_dir``, then bind it from the body with ``knit_artifact``:

.. knit-code:: /_code/artifacts.sh
   :language: bash
   :start-after: # START declare
   :end-before: # END declare

The ``<linked-path>`` you bind is always **inside** the artifacts root, given
relative to it (``table.csv``) or as an absolute path within it; a path outside
the root is fatal. knit records the artifact's value as that
**artifacts-relative** path, so the database holds no absolute machine path and
the record stays relocatable. Add ``--result`` (as on ``table`` here) to mark the
artifact as the headline result too (see *Mark an output as the result*).

knit records each artifact as one row in the framework-owned ``artifacts`` table
--- its ``path``, ``name``, ``type``, content ``checksum``, and ``result`` flag
--- **not** as a column of the producing command's own table, and links that row
to the producing invocation with a ``produced`` provenance edge. The content
digest is **always** recorded (there is no ``--no-checksum`` opt-out for an
artifact). Because each artifact is its own node, *which invocation produced this
file?* is a reverse walk of the ``produced`` edge (see *Trace an artifact back to
its producer*), and ``knit describe`` lists artifacts in a dedicated Artifacts
section, separate from the value outputs. The entry must exist and match its
declared type when you bind it. Artifacts are **write-once**: binding the same
path twice is fatal, so a command re-run that produces a fixed-named artifact
needs a distinct ``<linked-path>`` per run. To create the entry from a file that
lives elsewhere, use the ``--link-from`` / ``--copy-from`` shortcuts (see *Link
or copy an artifact into place*).
