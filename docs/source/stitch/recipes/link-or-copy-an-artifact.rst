..
   title: Link or copy an artifact into place
   categories: artifacts
   order: 60
   description: Create an artifact from a file elsewhere with knit_artifact --copy-from (snapshot) or --link-from (reference in place).
   apis: knit_artifact

When the bytes you want as an artifact already live somewhere else, let
``knit_artifact`` place the entry for you instead of writing it under the
artifacts root by hand. ``--copy-from`` snapshots the source into ``artifacts/``;
``--link-from`` references it in place through an absolute-target symlink:

.. knit-code:: /_code/artifacts.sh
   :language: bash
   :start-after: # START shortcuts
   :end-before: # END shortcuts

Choose by cost and durability. ``--copy-from`` does ``cp -r``, so the artifact is
a self-contained copy --- right for a small file you want to keep even if the
original moves. ``--link-from`` makes a symlink whose target is resolved to an
absolute path, so a large file on a fast filesystem is referenced at zero copy
cost and stays where it is; a later export dereferences the link and streams the
real content into the archive.

Both shortcuts create any missing parent directories inside ``artifacts/`` and
**never overwrite** an existing on-disk entry (artifacts are write-once); the
source ``<real-path>`` must exist, and the two shortcuts are mutually exclusive.
Either way the entry then goes through the same existence, type, and checksum path
as a hand-placed one: the digest is taken from the **resolved target** (following
the symlink, recursing into a directory), so a linked artifact is checksummed as
if it were physically present. It is recorded exactly like a hand-placed artifact --- an ``artifacts`` row whose
``path`` is the artifacts-relative ``<linked-path>`` (see *Declare and bind an
artifact*).
