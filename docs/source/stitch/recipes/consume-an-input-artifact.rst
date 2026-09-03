..
   title: Consume an artifact by kind
   categories: artifacts, provenance
   order: 90
   description: Require a produced artifact of a given kind with knit_with_input_artifact, resolve it with knit_input_artifact_path, and record a used_by edge.
   apis: knit_with_input_artifact, knit_input_artifact_path

A command consumes an artifact another command produced by declaring
``knit_with_input_artifact "name:kind" "description"``. This registers a required
string parameter whose value is the **artifacts-relative path** of a recorded
artifact of that kind. In the body, ``knit_input_artifact_path`` resolves that
path to the on-disk file:

.. knit-code:: /_code/input_artifacts.sh
   :language: bash
   :start-after: # START consume
   :end-before: # END consume

Before the body runs, Knit resolves the path to its ``artifacts`` row and refuses
the run when the value is empty, when no artifact is recorded at that path, or
when the recorded artifact's kind is not the required one --- so the body never
sees the wrong kind of input. Add ``--verify-checksum`` (as here) to also re-hash
the bytes and refuse a run when the artifact changed since it was produced; the
digest recorded at production time is the reference. The kind must be registered
(builtin or via *Declare an artifact kind*).

Consuming an artifact records a ``used_by`` provenance edge **from the artifact's
row to the consuming invocation**, the mirror of the ``produced`` edge the
producer left. Together they complete the lineage ``producer --produced--> artifact
--used_by--> consumer``, which a single query walks end to end (see *Walk an
artifact's full lineage*). A plain file input that is *not* a recorded artifact
takes a bare path parameter instead and leaves no edge --- reach for
``knit_with_input_artifact`` only when the input is a tracked artifact whose
lineage you want.
