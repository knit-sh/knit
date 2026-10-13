#!/usr/bin/env bash
# doc-check: source-only
#
# The user side of plugins: import one near the top of the experiment, after
# sourcing knit.sh and before using what the plugin provides. This file is
# syntax-checked only (source-only), since an import fetches over the network.

source knit.sh

# START import
# Short form: expands to github.com/knit-sh/knit-<name>.
knit_import spack

# Pin a ref (tag, branch, or commit). A mutable ref is resolved to a commit on
# the first bootstrap and frozen in knit-plugins.lock.
knit_import spack@v1.2.0

# Full form names the host, owner, and repository.
knit_import github.com/your-org/knit-example@v1.0.0

# Optionally hard-pin the tarball checksum.
knit_import spack@v1.2.0 \
    --sha256 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
# END import

knit "$@"
