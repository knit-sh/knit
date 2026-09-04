..
   title: Consume many artifacts with a glob
   categories: artifacts
   order: 95
   description: Declare a +/* input artifact and read every member with knit_input_artifact_paths, passing a comma list or a glob.
   apis: knit_with_input_artifact, knit_input_artifact_paths

A ``*`` (zero or more) or ``+`` (one or more) on an **input** artifact lets one
parameter stand for a whole set. Its argument is a comma-separated list of
artifacts-relative paths, and any element holding a glob metacharacter
(``*``, ``?``, ``[``) is expanded against the artifacts root --- so a single
``--shards 'shard-*.csv'`` gathers a whole fan-out. ``knit_input_artifact_paths``
fills a bash array with the resolved on-disk paths, in order, de-duplicated:

.. knit-code:: /_code/variadic_artifacts.sh
   :language: bash
   :start-after: # START glob
   :end-before: # END glob

Every resolved member is validated before the body runs --- containment,
existence, and recorded kind (plus the checksum with ``--verify-checksum``) ---
and the first bad element is fatal and names itself, so the body never sees a
partial or wrong-kind set. ``+`` refuses an empty result (the parameter is
required, and a glob matching nothing is fatal); ``*`` accepts it (the parameter
is optional and defaults to empty, and the array simply comes back empty). Quote
the glob so your shell does not expand it before Knit does. The consumer's own
row stores the **raw** argument you passed (the pattern), while one ``used_by``
edge is recorded per resolved member --- so the lineage carries the concrete set,
not the pattern. For a single artifact, use the scalar ``knit_input_artifact_path``
instead (see *Consume an artifact by kind*).
