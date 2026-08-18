#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# image-tag.sh — Deterministic content tag for a cluster's Docker build context.
#
# Usage:
#   image-tag.sh slurm|pbs|flux
#
# Prints a short, stable hash (12 hex chars) of the entire
# tests/integration/docker/<cluster>/ tree — the Dockerfile, docker-compose.yml
# (which carries the SLURM_VERSION / PBS_VERSION / FLUX_TAG defaults), and any
# conf/scripts.
# Both the publish workflow and the test workflow call THIS script so they always
# agree on the tag; a registry miss on the requested tag means "the build context
# changed and no image was published for it" (build locally instead).
#
# File contents AND their relative paths feed the hash, so a rename or a one-byte
# edit changes the tag. Paths are relative to the context dir, so the result is
# independent of where the repository is checked out.
# ------------------------------------------------------------------------------
set -euo pipefail

cluster="${1:-}"
case "${cluster}" in
    slurm|pbs|flux) ;;
    *)
        printf 'Usage: %s slurm|pbs|flux\n' "$(basename "$0")" >&2
        exit 1
        ;;
esac

# Resolve the docker context dir relative to this script (…/tests/integration/lib).
lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
context_dir="${lib_dir}/../docker/${cluster}"

if [[ ! -d "${context_dir}" ]]; then
    printf 'No docker context directory for cluster "%s" at %s\n' \
        "${cluster}" "${context_dir}" >&2
    exit 1
fi

# Hash every file in the context, in a locale-stable order, then hash the digest
# list down to a single value and take the first 12 hex chars.
(
    cd "${context_dir}"
    find . -type f -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum \
        | sha256sum \
        | cut -c1-12
)
