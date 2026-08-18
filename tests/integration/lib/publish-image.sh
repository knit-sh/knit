#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# publish-image.sh — Push a cluster's Docker image to ghcr.io (CI/main only).
#
# Usage:
#   publish-image.sh slurm|pbs|flux
#
# Tags the locally-available compose image (slurm-learn / openpbs-cluster /
# flux-cluster :latest) as
#   ghcr.io/<owner>/knit-<cluster>-cluster:<content-hash>   (lib/image-tag.sh)
#   ghcr.io/<owner>/knit-<cluster>-cluster:latest
# and pushes both.
#
# This is the ONLY push path in the integration-test flow, and it is deliberately
# opt-in so that `make check` / local runs never publish:
#   * It is a no-op unless KNIT_IMAGE_PUBLISH=1 (the tests workflow sets this only
#     on main, on non-pull_request events).
#   * It only pushes an image that was BUILT this run (per the state marker written
#     by lib/provision-image.sh) — a warm pull already matches the published
#     :<hash>, so re-pushing it would be redundant.
#
# Environment:
#   KNIT_IMAGE_PUBLISH      must be "1" or this script skips (never pushes).
#   KNIT_IMAGE_OWNER        ghcr owner to push to (local override).
#   GITHUB_REPOSITORY_OWNER ghcr owner in GitHub Actions (used if the above unset).
# ------------------------------------------------------------------------------
set -euo pipefail

cluster="${1:-}"
case "${cluster}" in
    slurm) compose_image="slurm-learn:latest" ;;
    pbs)   compose_image="openpbs-cluster:latest" ;;
    flux)  compose_image="flux-cluster:latest" ;;
    *)
        printf 'Usage: %s slurm|pbs|flux\n' "$(basename "$0")" >&2
        exit 1
        ;;
esac

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_file="${lib_dir}/.image-state-${cluster}"

# Opt-in gate: never push unless explicitly enabled. Keeps local runs push-free.
if [[ "${KNIT_IMAGE_PUBLISH:-}" != "1" ]]; then
    printf '[publish] KNIT_IMAGE_PUBLISH not set — skipping publish of %s\n' "${cluster}"
    exit 0
fi

# Only publish an image we built this run; a warm pull already matches the
# published :<hash>, so re-pushing it is redundant.
state="$(cat "${state_file}" 2>/dev/null || true)"
if [[ "${state}" != "built" ]]; then
    printf '[publish] %s image was not built this run (state=%s) — nothing to push\n' \
        "${cluster}" "${state:-none}"
    exit 0
fi

registry="ghcr.io"
# ghcr requires a lowercase owner.
owner="${KNIT_IMAGE_OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
owner="${owner,,}"
if [[ -z "${owner}" ]]; then
    printf '[publish] no image owner set (KNIT_IMAGE_OWNER / GITHUB_REPOSITORY_OWNER); cannot publish\n' >&2
    exit 1
fi

tag="$(bash "${lib_dir}/image-tag.sh" "${cluster}")"
image="${registry}/${owner}/knit-${cluster}-cluster"

printf '[publish] tagging %s as %s:%s and %s:latest\n' \
    "${compose_image}" "${image}" "${tag}" "${image}"
docker tag "${compose_image}" "${image}:${tag}"
docker tag "${compose_image}" "${image}:latest"

printf '[publish] pushing %s:%s\n' "${image}" "${tag}"
docker push "${image}:${tag}"
printf '[publish] pushing %s:latest\n' "${image}"
docker push "${image}:latest"
