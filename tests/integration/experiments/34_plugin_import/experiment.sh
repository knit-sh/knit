#!/usr/bin/env bash
# Integration experiment 34_plugin_import.
#
# A minimal experiment that imports a plugin live from github.com. The import
# resolves and fetches at source time, before any command runs, so every
# invocation of this script (bootstrap included) makes the plugin's commands
# available.
# ------------------------------------------------------------------------------
source knit.sh

# Import the template plugin, pinned to a release tag. The first run resolves the
# tag to a commit and fetches it; later runs are offline cache hits. The resolved
# commit and checksum are frozen in knit-plugins.lock, and bootstrap records the
# plugin in the "plugins" table and materializes its tree under .knit/plugins/.
knit_import github.com/knit-sh/knit-template-plugin@v1.0.0

knit "$@"
