#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# provision-image.sh — Make a cluster's Docker image available locally, cheaply.
#
# Usage:
#   provision-image.sh slurm|pbs|flux
#
# Tries to PULL the prebuilt image from ghcr.io at the exact content tag for the
# current build context (lib/image-tag.sh) and retags it to the name the compose
# file expects (slurm-learn / openpbs-cluster / flux-cluster :latest), so a subsequent
# `docker compose up -d` (no --build) reuses it. On any miss — tag not published,
# no registry access, or no owner configured — it falls back to a local build
# (make build-<cluster>).
#
# Staleness short-circuit. Every image made available (built or pulled) is also
# tagged with its content tag (<name>:<hash>). If that tagged image already exists
# locally and the compose :latest tag points at the same image id, the local image
# already matches the current docker/<cluster>/ context and the script reuses it —
# pulling and building nothing. This makes the Makefile's cluster-up targets safe
# to call this script on every run: a stale local image rebuilds automatically
# only when the context actually changes (a new tag the local image lacks), which
# is what keeps a local run in step with CI instead of reusing a months-old image.
#
# It records how the image was obtained in a state marker
# (lib/.image-state-<cluster> = "built" or "pulled") so the publish step
# (lib/publish-image.sh) can push only images that were actually built this run.
# The reuse short-circuit leaves the marker untouched, so a prior "built" marker
# still drives publishing when CI calls this twice (its own step, then cluster-up).
#
# This script NEVER pushes. Publishing to ghcr.io is done ONLY by the publish
# step of the tests workflow, which runs solely inside GitHub Actions on main.
# That is what keeps `make check` / `make check-integration` working locally with
# no GitHub environment: locally this either pulls a public image (a free
# speedup) or builds, and never attempts a push (which would fail without a
# GITHUB_TOKEN).
#
# Environment:
#   KNIT_IMAGE_OWNER        ghcr owner to pull from (local override).
#   GITHUB_REPOSITORY_OWNER ghcr owner in GitHub Actions (used if the above unset).
#   KNIT_IMAGE_FORCE_BUILD  when "1", skip the pull and build locally. Used by the
#                           weekly/manual runs so a rebuild picks up fresh base
#                           layers even though the content tag is unchanged.
# With neither owner set, no pull is attempted and the image is built locally.
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
integration_dir="${lib_dir}/.."
state_file="${lib_dir}/.image-state-${cluster}"

registry="ghcr.io"
# ghcr requires a lowercase owner.
owner="${KNIT_IMAGE_OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
owner="${owner,,}"

# The content tag of the current build context, and the local image name that
# carries it. Every image this script makes available (built or pulled) is tagged
# BOTH as the compose name (:latest, what compose runs) and as this content tag,
# so a later run can tell whether the local :latest still matches the current
# docker/<cluster>/ context — the staleness short-circuit below.
tag="$(bash "${lib_dir}/image-tag.sh" "${cluster}")"
content_image="${compose_image%:*}:${tag}"

# Record how the image was obtained ("built" | "pulled") for publish-image.sh.
mark_state() {
    printf '%s\n' "$1" > "${state_file}"
}

build_locally() {
    printf '[provision] building %s image locally\n' "${cluster}"
    make -C "${integration_dir}" "build-${cluster}"
    docker tag "${compose_image}" "${content_image}"
    mark_state built
}

# Forced rebuild (weekly/manual): skip the pull so fresh base layers are picked
# up even when the content tag already exists in the registry.
if [[ "${KNIT_IMAGE_FORCE_BUILD:-}" == "1" ]]; then
    printf '[provision] KNIT_IMAGE_FORCE_BUILD=1 — forcing a local build\n'
    build_locally
    exit 0
fi

# Staleness short-circuit: the local :latest already carries the current content
# tag (same image id), so it is up to date — reuse it, pull or build nothing. This
# makes repeat calls cheap (the Makefile's cluster-up targets call this script
# every run) and makes a stale local image rebuild automatically only when the
# docker/<cluster>/ context actually changes (a new tag the local image lacks).
# State is left untouched so a prior "built" marker still drives publishing in CI.
if docker image inspect "${content_image}" >/dev/null 2>&1; then
    latest_id="$(docker image inspect -f '{{.Id}}' "${compose_image}" 2>/dev/null || true)"
    content_id="$(docker image inspect -f '{{.Id}}' "${content_image}")"
    if [[ -n "${latest_id}" && "${latest_id}" == "${content_id}" ]]; then
        printf '[provision] local %s image is current (%s); reusing\n' \
            "${cluster}" "${tag}"
        exit 0
    fi
fi

# No owner configured (typical bare local run): build, do not attempt a pull.
if [[ -z "${owner}" ]]; then
    printf '[provision] no image owner set (KNIT_IMAGE_OWNER / GITHUB_REPOSITORY_OWNER); building locally\n'
    build_locally
    exit 0
fi

image="${registry}/${owner}/knit-${cluster}-cluster:${tag}"

printf '[provision] trying to pull %s\n' "${image}"
if docker pull "${image}"; then
    printf '[provision] pulled; retagging to %s\n' "${compose_image}"
    docker tag "${image}" "${compose_image}"
    docker tag "${image}" "${content_image}"
    mark_state pulled
else
    printf '[provision] pull failed (unpublished tag or no access); building locally\n'
    build_locally
fi
