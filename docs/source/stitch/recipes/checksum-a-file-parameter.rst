..
   title: Checksum a file or directory parameter
   categories: types, recording
   order: 30
   description: Record the path and a sha256 content checksum of a file/directory input or output, and opt out with --no-checksum.
   apis: knit_with_required, knit_with_optional, knit_with_output, knit_output, knit_with_table

A parameter or output typed ``file`` or ``directory`` (alias ``dir``) is more
than a string: knit checks it exists at runtime and, by default, fingerprints its
content with a sha256. Declare them as usual — no extra call is needed:

.. knit-code:: /_code/types.sh
   :language: bash
   :start-after: # START checksum
   :end-before: # END checksum

With ``knit_with_table`` in place, each such parameter records **two** columns:
the path (``input``, ``summary``, ``workdir``) and, next to it, a companion
``<name>_checksum`` holding ``sha256:<hex>``. So ``report --input data.txt``
leaves a row whose ``input`` is ``data.txt`` and whose ``input_checksum`` is the
digest of that file's bytes.

The digest is computed off the timed path and reflects the artifact as used: an
**input** is hashed before the body runs, an **output** after it returns. A
``directory`` is hashed recursively over its structure and contents. Existence is
enforced by direction: a missing required input is fatal before the body runs; a
declared output missing on a successful completion is an error.

Append ``--no-checksum`` to record the path only, skipping the hash — useful for a
large or volatile artifact whose content you do not want to fingerprint (here the
``workdir`` scratch tree). Such a declaration has no ``<name>_checksum`` column,
but existence is still checked. ``--no-checksum`` on a non-file/directory type is
a declaration error.
