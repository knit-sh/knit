..
   title: Discover and merge a fan-out
   categories: artifacts, provenance
   order: 100
   description: Pair a *-output producer with a +/* -input consumer so one command scatters many artifacts and the next gathers them by glob.
   apis: knit_with_output_artifact, knit_artifact, knit_with_input_artifact, knit_input_artifact_paths

Variadic artifacts compose into a **discover-and-merge** pattern across two
commands: a producer fans out a ``*`` collection, and a consumer gathers the
whole set through a ``+`` input with one glob argument --- without either side
hard-coding how many members there are. The producer binds one collection name
per member:

.. knit-code:: /_code/variadic_artifacts.sh
   :language: bash
   :start-after: # START fanout
   :end-before: # END fanout

The consumer discovers them with a glob and merges what it finds:

.. knit-code:: /_code/variadic_artifacts.sh
   :language: bash
   :start-after: # START glob
   :end-before: # END glob

Run them in sequence --- ``shard --n 3`` then ``merge --shards 'shard-*.csv'``
--- and the glob resolves to whatever the fan-out produced. The provenance keeps
each member distinct on both sides: the producer leaves one ``produced`` edge per
bound member, and the consume leaves one ``used_by`` edge per resolved member, so
the lineage ``producer --produced--> member --used_by--> consumer`` holds for
every file in the set. One join over the two edge kinds recovers the whole group,
and *what merged this shard?* or *which shards fed this merge?* are the two ends
of that same walk (see *Walk an artifact's full lineage*). This scales a sweep
without a fixed member count: add more shards and the same glob gathers them.
