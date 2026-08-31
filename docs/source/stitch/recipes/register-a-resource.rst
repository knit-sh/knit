..
   title: Register a resource type
   categories: resources
   order: 10
   description: Declare how to acquire an input artifact with knit_register_resource and a download decorator.
   apis: knit_register_resource, knit_with_local, knit_with_git, knit_with_url

A *resource* is a named, downloadable input artifact --- a dataset or a piece of
third-party source code. ``knit_register_resource`` declares a resource *type*:
what the artifact is and, through exactly one download decorator, how to acquire
it. There is no body to write; knit supplies the download itself.

.. knit-code:: /_code/resources.sh
   :language: bash
   :start-after: # START register
   :end-before: # END register

Pick the decorator that matches the source: ``knit_with_local <path>`` links or
copies a path already on disk, ``knit_with_git <url> <ref>`` clones a repository
at a ref, and ``knit_with_url <url>`` downloads (and optionally uncompresses) an
archive. Add ``knit_with_checksum <sha256>`` to pin the artifact's integrity.
