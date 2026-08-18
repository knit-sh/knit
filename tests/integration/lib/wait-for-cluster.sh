#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# wait-for-cluster.sh — Poll until the job manager is ready to accept commands.
#
# Usage:
#   wait-for-cluster.sh slurm|pbs|flux
#
# Exits 0 when the cluster is ready, 1 if the timeout is reached.
# This script is run inside the login container (via docker exec) by the
# integration test Makefile after `docker compose up`.
# ------------------------------------------------------------------------------
set -euo pipefail

TYPE="${1:-}"

# is_ready — return 0 once the cluster can accept work. For slurm/pbs it is
# enough that the control command answers; for flux we also wait until both
# compute nodes have joined the overlay, so a job that asks for two nodes right
# after startup does not fail for lack of resources.
is_ready() {
    case "${TYPE}" in
        slurm) sinfo &>/dev/null ;;
        pbs)   pbsnodes -a &>/dev/null ;;
        flux)
            local up
            up="$(flux resource list -s up -no '{nnodes}' 2>/dev/null || echo 0)"
            [[ "${up}" =~ ^[0-9]+$ ]] && (( up >= 2 ))
            ;;
        *) return 2 ;;
    esac
}

case "${TYPE}" in
    slurm|pbs|flux) ;;
    *)
        printf 'Usage: %s slurm|pbs|flux\n' "$(basename "$0")" >&2
        exit 1
        ;;
esac

TIMEOUT=120
INTERVAL=3
elapsed=0

printf 'Waiting for %s cluster (timeout %ds)...\n' "${TYPE}" "${TIMEOUT}"
while ! is_ready; do
    if (( elapsed >= TIMEOUT )); then
        printf 'Timed out waiting for %s cluster after %ds.\n' "${TYPE}" "${TIMEOUT}" >&2
        exit 1
    fi
    sleep "${INTERVAL}"
    elapsed=$(( elapsed + INTERVAL ))
done
printf '%s cluster ready after %ds.\n' "${TYPE}" "${elapsed}"
