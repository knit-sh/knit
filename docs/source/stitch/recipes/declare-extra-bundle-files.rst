..
   title: Declare extra files to bundle
   categories: bundle
   order: 20
   description: List side files Knit does not track — a config, an input, a plotting script, or a whole glob — with knit_bundle_requires so knit bundle carries them.
   apis: knit_bundle_requires

An experiment often needs files Knit never tracks: a config, a small input, a
post-processing script. ``knit_bundle_requires`` lists them so ``knit bundle``
(see *Make a shippable bundle*) carries them. Call it at the top of the script,
like ``knit_set_program_description`` --- not inside a command:

.. knit-code:: /_code/bundle.sh
   :language: bash
   :start-after: # START requires
   :end-before: # END requires

Rules:

- **Relative paths only.** Each path is relative to the experiment script, so it
  relocates cleanly when the archive is unpacked. An absolute path is rejected at
  bundle time.
- **A file, a directory, or a glob.** A directory is added with its contents. A
  glob (``inputs/*.dat``) is expanded at *bundle* time and every match is packed;
  a pattern that matches nothing draws a warning.
- **Record-only at load time.** The declaration never touches the filesystem ---
  no existence check, no error. That keeps re-sourcing the script safe (a job
  re-enters it on the compute node). All validation --- the path exists, is
  relative, and stays inside the tree --- happens when ``knit bundle`` runs.

A file kept its path relative to the script root, so ``config/params.yaml`` lands
at ``<bundle-root>/config/params.yaml``. The ``@bundle_requires`` shorthand is an
equivalent twin. A setup that declares a Spack environment from a file
(``knit_with_spack_env "envs/mclib.yaml"``) records that file automatically ---
no extra ``knit_bundle_requires`` needed.
