..
   title: Declare an artifact kind
   categories: artifacts
   order: 80
   description: Give an artifact a semantic kind with knit_register_artifact, then produce it by naming the kind in knit_with_output_artifact.
   apis: knit_register_artifact, knit_with_output_artifact, knit_artifact

An artifact's **type** is its physical form --- ``file`` or ``directory``. Its
**kind** is what it *means*: a CSV table, a checkpoint, a mesh. A kind is a
semantic label backed by exactly one physical type, so a consumer can require *a
CSV table* rather than merely *a file*. Declare a kind once at the top level with
``knit_register_artifact "kind:type" "description"``, then a producer names the
kind in place of the bare physical type:

.. knit-code:: /_code/input_artifacts.sh
   :language: bash
   :start-after: # START kind
   :end-before: # END kind

``file``, ``directory``, and the ``dir`` alias are **builtin** kinds --- they are
their own physical type and need no declaration, so ``"table:file"`` keeps
working unchanged (see *Declare and bind an artifact*). A named kind is declared
once; redefining any kind (a builtin included) is fatal, and the physical
``type`` must itself be ``file`` or ``directory``.

The kind is recorded in the ``kind`` column of the framework-owned ``artifacts``
table, next to the physical ``type``; a bare ``table:file`` records
``type=file, kind=file``, while ``table:csvfile`` records ``type=file,
kind=csvfile``. ``knit describe`` shows the kind (not the bare type) for a
declared output artifact. The kind is the contract a consumer checks against ---
see *Consume an artifact by kind*.
